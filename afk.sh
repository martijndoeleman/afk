#!/usr/bin/env bash
#
# afk.sh — run a coding agent headlessly inside one
# long-lived sbx sandbox. Defaults to Claude Code; see AGENT.
#
# Continuity between agent sessions inside the sandbox comes from 
# files + git history inside the sandbox's clone, not from conversation history
#
# Settings come from three places, in order: the environment, the repository's
# .afkrc, then the built-in defaults.
#   MAX_ITERATIONS=2 BOX=test-box afk loop     # one run
#   afk init                              # freeze settings into ./.afkrc
#
# Subcommands:
#   afk init            # write .afkrc for this repository
#   afk config          # show current settings and where they come from
#   afk loop            # run the agent in a loop with $PROMPT_FILE as instructions
#   afk prompt <text>   # run the agent once on an ad-hoc prompt
#   afk prompt < FILE   # the same, with the prompt read from a file
#   afk smoke           # verify sandbox + auth + network, no real work
#   afk shell           # drop into the sandbox's shell to poke around or do ad-hoc work
#   afk remove          # destroy the sandbox
#
# Installed as `afk` by running install.sh; run `afk` as ./afk.sh if you'd rather not
# install it. Both take the same subcommands.

set -uo pipefail

# ==============================================================================
# SETTINGS
# ==============================================================================
#
# Every setting afk has, in one list: NAME|default|what it is. This is the only
# place a setting is declared. It is the whitelist load_repo_config validates
# .afkrc against, the defaults apply_defaults falls back to, the template
# `afk init` writes and the table `afk config` prints — so a setting added here
# turns up in all four without touching them.
#
# Entries starting with `#|` are section headings for the generated .afkrc and
# are skipped everywhere else.
SETTINGS=(
  "#|sandbox"
  "BOX||sandbox name. One per repository — the default is this directory's name"
  "AGENT|claude|claude, codex or copilot (see AGENT PROFILES)"
  "USE_CLONE|1|1 = private in-VM clone, 0 = mount your working tree directly"
  "BRANCH|afk-agent|branch the agent commits to"
  "CPUS|0|0 = auto (all host CPUs)"
  "MEMORY||e.g. 8g; empty = the sbx default"
  "#|loop control"
  "MAX_ITERATIONS|10|hard cap on iterations; always set one"
  "TIMEOUT|3600|seconds an iteration may run before the agent is killed; 0 = no limit"
  "SLEEP_BETWEEN|0|seconds between iterations"
  "STOP_ON_NO_COMMIT|1|bail if an iteration commits nothing"
  "#|the prompt"
  "PROMPT_FILE|PROMPT.md|the only input to \`loop\` — it is the prompt"
  "DONE_SENTINEL|ALL_DONE|what the agent says when the list is finished"
  "MODEL||empty = the agent profile's default (claude: opus)"
  "EFFORT|medium|low, medium, high, xhigh or max; empty = the agent's default"
  "#|output"
  "LOG_DIR|./.afk-logs|per-iteration JSON, and any bundle a failed fetch leaves"
)

CONFIG_FILE=".afkrc"      # per-repository settings, at the repository root
CONFIG_PATH=""            # set by load_repo_config when one was actually read

# ==============================================================================
# INTERNALS
# ==============================================================================

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing dependency: $1"; }

# REPO = The repository afk operates on: the one containing the current directory.
# Everything downstream — the directory mounted into the VM, the `git fetch` that
# brings the branch back, LOG_DIR, and PROMPT_FILE — resolves against it.
REPO=""
resolve_repo() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository — cd into the repo you want worked on"
  [[ -n "$top" ]] || die "no repository root here (a bare repo?) — cd into a working tree"
  REPO="$(cd "$top" && /bin/pwd -P)" || die "cannot enter repository root: $top"
  cd "$REPO" || die "cannot enter repository root: $REPO"
}

# ==============================================================================
# SETTINGS RESOLUTION
# ==============================================================================
#
# Three layers, highest first: the environment, $REPO/$CONFIG_FILE, the defaults
# in SETTINGS. Where a value came from is recorded in AFK_SRC_<NAME> so `config`
# can show it and `init` knows which lines to write out uncommented.

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

setting_names() {
  local e
  for e in "${SETTINGS[@]}"; do
    [[ "$e" == '#|'* ]] && continue
    printf '%s\n' "${e%%|*}"
  done
}

setting_field() {  # <name> <1=default|2=comment>
  local e rest
  for e in "${SETTINGS[@]}"; do
    [[ "${e%%|*}" == "$1" ]] || continue
    rest="${e#*|}"
    [[ "$2" == 1 ]] && { printf '%s' "${rest%%|*}"; return; }
    printf '%s' "${rest#*|}"; return
  done
}

# BOX is the one default that cannot be a constant: the whole point is that a
# different repository gets a different sandbox without being told to. sbx names
# are restrictive, so anything the directory name might contain and a name may
# not becomes a dash.
default_box() {
  local name
  name="$(basename "$REPO" | tr -c 'A-Za-z0-9._-' '-')"
  name="$(trim "${name//$'\n'/}")"
  while [[ "$name" == -* ]]; do name="${name#-}"; done
  while [[ "$name" == *- ]]; do name="${name%-}"; done
  printf '%s' "${name:-afk}"
}

setting_default() {
  [[ "$1" == BOX ]] && { [[ -n "$REPO" ]] && default_box || printf 'afk'; return; }
  setting_field "$1" 1
}

# Runs before anything else can touch these names, so "already set" can only
# mean "came from the environment".
snapshot_env() {
  local n
  for n in $(setting_names); do
    if [[ -n "${!n+x}" ]]; then printf -v "AFK_SRC_$n" '%s' env
    else                        printf -v "AFK_SRC_$n" '%s' default; fi
  done
}

src_of() { local v="AFK_SRC_$1"; printf '%s' "${!v}"; }

# .afkrc is parsed, never sourced. It arrives with the repository, and `cd`ing
# into a repository and typing `afk loop` must not be able to run that
# repository's shell code on your host — that is what the microVM is for. So:
# literal KEY=value only, no expansion, no substitution, and an unknown key is
# an error rather than a line that silently does nothing.
load_repo_config() {
  local path="$REPO/$CONFIG_FILE"
  [[ -f "$path" ]] || return 0
  CONFIG_PATH="$path"

  local line n=0 key val known
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == '#'* ]] && continue
    [[ "$line" == *=* ]] || die "$CONFIG_FILE:$n: not KEY=value: $line"

    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"

    known=""
    for known in $(setting_names); do [[ "$known" == "$key" ]] && break; done
    if [[ "$known" != "$key" ]]; then
      # MAX_TURNS bounded turns, and only for claude. TIMEOUT bounds wall clock
      # for every agent, and is the one that can end a run that has hung.
      [[ "$key" == MAX_TURNS ]] \
        && die "$CONFIG_FILE:$n: MAX_TURNS was removed — use TIMEOUT (seconds per iteration)"
      die "$CONFIG_FILE:$n: unknown setting $key — see \`$(basename "$0") config\`"
    fi

    # A trailing comment is stripped only when unquoted and preceded by space,
    # so a value that really contains a # keeps it by being quoted.
    if [[ "$val" != '"'* && "$val" != "'"* && "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]]; then
      val="$(trim "${BASH_REMATCH[1]}")"
    fi
    if [[ ${#val} -ge 2 && ( ( "$val" == '"'*'"' ) || ( "$val" == "'"*"'" ) ) ]]; then
      val="${val:1:${#val}-2}"
    fi

    # The environment wins, so a value set there is left alone — but the file
    # still says what it says, and `config` reports env as the source.
    [[ "$(src_of "$key")" == env ]] && continue
    printf -v "$key" '%s' "$val"
    printf -v "AFK_SRC_$key" '%s' file
  done < "$path"
}

apply_defaults() {
  local n
  for n in $(setting_names); do
    [[ -n "${!n+x}" ]] || printf -v "$n" '%s' "$(setting_default "$n")"
  done
}

# What the file changed, on one line next to the repository it belongs to.
report_config() {
  [[ -n "$CONFIG_PATH" ]] || return 0
  local n out=""
  for n in $(setting_names); do
    [[ "$(src_of "$n")" == file ]] && out+=" $n=${!n}"
  done
  log "config: $CONFIG_FILE$out"
}

box_exists() { sbx ls -q 2>/dev/null | grep -qx "$BOX"; }

ensure_box() {
  if box_exists; then
    log "reusing sandbox $BOX"
    return
  fi
  log "creating sandbox $BOX"
  # `sbx create` makes the sandbox without attaching an interactive session,
  # which is what we want — we drive it with `sbx exec`. (`sbx run` attaches.)
  local args=(--name "$BOX")
  [[ "$USE_CLONE" == "1" ]] && args+=(--clone)
  [[ "$CPUS" != "0" ]]      && args+=(--cpus "$CPUS")
  [[ -n "$MEMORY" ]]        && args+=(-m "$MEMORY")
  args+=("$AGENT" "$REPO")
  sbx create "${args[@]}" || die "sandbox creation failed"
}

in_box() { sbx exec "$BOX" "$@"; }

# Every agent invocation goes through here, so the bound is in one place.
# `timeout` runs inside the sandbox so that it kills the agent itself.
run_agent() {
  local status
  if [[ "$TIMEOUT" -gt 0 ]]; then
    in_box timeout "$TIMEOUT" "$AGENT" "${AGENT_FLAGS[@]}" </dev/null
  else
    in_box "$AGENT" "${AGENT_FLAGS[@]}" </dev/null
  fi
  status=$?
  [[ $status -eq 124 ]] && warn "$AGENT hit TIMEOUT (${TIMEOUT}s) and was killed"
  return $status
}

head_sha() { in_box git rev-parse HEAD 2>/dev/null | tr -d '\r\n'; }

# The prompt used is in $PROMPT_FILE, read from inside the sandbox.
# Thus, the $PROMPT_FILE must be a commited file prior to sandbox creation
# load_prompt also checks for empty $PROMPT_FILE and 
# the presence of a $DONE_SENTINEL - which should stop an agent when work is complete
PROMPT=""
SENTINEL_WARNED=""
load_prompt() {
  in_box test -f "$PROMPT_FILE" \
    || die "$PROMPT_FILE not found in the sandbox workspace — commit it, then \`$(basename "$0") remove\`"
  PROMPT="$(in_box cat "$PROMPT_FILE")" || die "could not read $PROMPT_FILE from the sandbox"
  [[ -n "${PROMPT//[[:space:]]/}" ]] || die "$PROMPT_FILE is empty — it is the prompt, so there is nothing to run"
  if [[ -z "$SENTINEL_WARNED" && "$PROMPT" != *"$DONE_SENTINEL"* ]]; then
    SENTINEL_WARNED=1
    warn "$PROMPT_FILE never mentions $DONE_SENTINEL — the loop can only stop on MAX_ITERATIONS"
  fi
}

# ==============================================================================
# AGENT PROFILES
# ==============================================================================
#
# Agents differ in two ways: how to invoke them headlessly, and how to recover
# the final assistant message. Adding a docker sandbox compatible agent requires
# adding an agent profile below.
#
# Each agent profile defines:
#   build_agent_flags <prompt>               -> sets the AGENT_FLAGS array
#   agent_text  <raw_output>                 -> prints the final message
#   agent_failed <raw_output>                -> true if the run errored

CODEX_LAST_MSG="/tmp/afk-last-message.txt"

select_agent_profile() {
case "$AGENT" in
  claude)
    MODEL="${MODEL:-opus}"
    build_agent_flags() {
      AGENT_FLAGS=(
        -p "$1"
        --dangerously-skip-permissions
        --output-format json
      )
      [[ -n "$MODEL" ]]  && AGENT_FLAGS+=(--model "$MODEL")
      [[ -n "$EFFORT" ]] && AGENT_FLAGS+=(--effort "$EFFORT")
      return 0
    }
    agent_text()   { jq -r '.result // empty'        <<<"$1"; }
    agent_failed() { [[ "$(jq -r '.is_error // false' <<<"$1")" == "true" ]]; }
    ;;

  codex)
    # `codex exec` is the non-interactive entry point, and it is shaped quite
    # differently from Claude Code:
    #   - --json emits a stream of JSONL events, not one result object, so the
    #     final message is recovered from --output-last-message instead.
    #   - reasoning effort is a config override, not a flag.
    build_agent_flags() {
      AGENT_FLAGS=(
        exec
        --json
        --dangerously-bypass-approvals-and-sandbox
        --output-last-message "$CODEX_LAST_MSG"
      )
      [[ -n "$MODEL" ]]  && AGENT_FLAGS+=(-m "$MODEL")
      [[ -n "$EFFORT" ]] && AGENT_FLAGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
      AGENT_FLAGS+=("$1")
      return 0
    }
    agent_text()   { in_box cat "$CODEX_LAST_MSG" 2>/dev/null; }
    agent_failed() { grep -q '"type":"turn.failed"' <<<"$1"; }
    ;;

  copilot)
    # GitHub Copilot CLI. `-p` is its non-interactive entry point; it exits 0 on
    # success and 1 on error, and in JSON mode writes nothing to stderr.
    #   - --allow-all is --allow-all-tools + --allow-all-paths + --allow-all-urls,
    #     the same as the --yolo the sbx template starts copilot with. The VM is
    #     the boundary. --allow-all-tools alone is required in prompt mode.
    #   - --no-ask-user disables the ask_user tool, so an unattended run cannot
    #     block on a question nobody is there to answer.
    #   - --output-format json is JSONL: one event per line, ending in a single
    #     {"type":"result","exitCode":N,...}. The reply is the last
    #     assistant.message; a session.error turns up as its own event.
    # Auth is a GitHub token with Copilot access, given to the sandbox with
    #   sbx secret set github --command 'gh auth token'
    build_agent_flags() {
      AGENT_FLAGS=(
        --allow-all
        --no-ask-user
        --log-level none
        --output-format json
      )
      [[ -n "$MODEL" ]]  && AGENT_FLAGS+=(--model "$MODEL")
      [[ -n "$EFFORT" ]] && AGENT_FLAGS+=(--effort "$EFFORT")
      AGENT_FLAGS+=(-p "$1")
      return 0
    }
    agent_text() {
      jq -rs '[.[] | select(.type == "assistant.message")] | last | .data.content // empty' <<<"$1"
    }
    # No result line means the run died before it could write one, so treat a
    # missing exitCode as a failure rather than a pass.
    agent_failed() {
      [[ "$(jq -rs 'map(select(.type == "result")) | last | .exitCode // 1' <<<"$1")" != "0" ]]
    }
    ;;

  *)
    die "no profile for AGENT=$AGENT (known: claude, codex, copilot)"
    ;;
esac
}

# ==============================================================================
# SUBCOMMANDS
# ==============================================================================

# Quote only when the value would not survive the parser unquoted.
quote_value() {
  case "$1" in
    ""|*[!A-Za-z0-9._/@:=+-]*) printf '"%s"' "$1" ;;
    *)                         printf '%s'   "$1" ;;
  esac
}

# Keeps LOG_DIR out of git: `init` appends it to $REPO/.gitignore. A LOG_DIR
# outside the repository, or one git already ignores, is left alone.
ignore_log_dir() {
  local dir="$LOG_DIR" entry

  [[ "$dir" == /* ]] && return 0            # absolute — not ours to ignore
  dir="${dir#./}"; dir="${dir%/}"
  [[ -n "$dir" && "$dir" != "." && "$dir" != ..* ]] || return 0

  entry="/$dir/"
  git -C "$REPO" check-ignore -q "$dir" 2>/dev/null && return 0
  grep -qxF "$entry" "$REPO/.gitignore" 2>/dev/null && return 0

  # A file without a trailing newline would swallow the entry onto its last line.
  [[ -s "$REPO/.gitignore" && -n "$(tail -c 1 "$REPO/.gitignore")" ]] \
    && printf '\n' >> "$REPO/.gitignore"
  printf '%s\n' "$entry" >> "$REPO/.gitignore" \
    || { warn "could not write $REPO/.gitignore — add $entry yourself"; return 0; }
  log "added $entry to .gitignore"
}

# afk init - Writes .afkrc: every setting displays its default, commented out.
#
# `AGENT=codex afk init` freezes the setup with defined variables
# Requires `FORCE=1 afk init` to regenerate the file if an .afkrc is already present
cmd_init() {
  local path="$REPO/$CONFIG_FILE" me; me="$(basename "$0")"
  [[ -e "$path" && "${FORCE:-0}" != "1" ]] \
    && die "$CONFIG_FILE already exists — FORCE=1 $me init to rewrite it"

  local e n src out=""
  out+="# $CONFIG_FILE — afk settings for this repository. Written by \`$me init\`."$'\n'
  out+="#"$'\n'
  out+="# Commit .afkrc to your git repository"$'\n'
  out+="# .afkrc automatically selects the correct \`afk\` configuration"$'\n'
  out+="# Environment variables still win over anything set below, and"$'\n'
  out+="# every commented-out line is showing afk's built-in defaults."$'\n'
  for e in "${SETTINGS[@]}"; do
    if [[ "$e" == '#|'* ]]; then
      out+=$'\n'"# --- ${e#\#|} ---"$'\n'
      continue
    fi
    n="${e%%|*}"
    src="$(src_of "$n")"
    out+="# $(setting_field "$n" 2)"$'\n'
    if [[ "$n" == BOX || "$src" != default ]]; then
      out+="$n=$(quote_value "${!n}")"$'\n'
    else
      out+="# $n=$(quote_value "$(setting_default "$n")")"$'\n'
    fi
  done

  printf '%s' "$out" > "$path" || die "could not write $path"
  log "wrote $path"
  ignore_log_dir
  log "sandbox for this repository: $BOX"
  [[ -f "$REPO/$PROMPT_FILE" ]] \
    || warn "no $PROMPT_FILE here yet — \`$me loop\` needs one; see the README"
}

# afk config - shows the current active afk config with source of the value
cmd_config() {
  local e n src
  printf '%-18s %-24s %s\n' SETTING VALUE SOURCE
  for e in "${SETTINGS[@]}"; do
    [[ "$e" == '#|'* ]] && continue
    n="${e%%|*}"
    src="$(src_of "$n")"
    [[ "$src" == file ]] && src="$CONFIG_FILE"
    printf '%-18s %-24s %s\n' "$n" "${!n:-(none)}" "$src"
  done
  [[ -n "$CONFIG_PATH" ]] || log "no $CONFIG_FILE here — \`$(basename "$0") init\` writes one"
}

# afk smoke - test box + auth + network + model in current afk config
cmd_smoke() {
  ensure_box
  log "workspace inside sandbox:"; in_box pwd
  log "git status:";               in_box git status --short --branch
  log "$AGENT version:";           in_box "$AGENT" --version
  log "round-trip test (checks auth + network + model):"
  build_agent_flags "Reply with exactly: PONG"
  local out; out=$(run_agent)
  agent_failed "$out" && { printf '%s\n' "$out" | tail -5; die "round-trip failed"; }
  printf '%s\n' "$(agent_text "$out")"
  log "smoke test passed"
}

# afk shell - drop in sandbox shell
cmd_shell() { ensure_box; sbx exec -it "$BOX" bash; }

# afk remove - remove sandbox
cmd_remove() {
  log "removing sandbox $BOX"
  sbx rm -f "$BOX" 2>/dev/null || true
  log "gone. next run will create it fresh."
}

# Switch to $BRANCH, creating it only if it is missing.
use_branch() {
  in_box git checkout "$BRANCH" 2>/dev/null \
    || in_box git checkout -b "$BRANCH" \
    || die "could not switch to branch $BRANCH"
}

# afk prompt - one agent run on a prompt you pass in.
# Changes are collected through git fetch so tell the agent to commit any work it does in the sandbox
cmd_prompt() {
  local prompt="$*"
  if [[ -z "$prompt" && ! -t 0 ]]; then prompt="$(cat)"; fi
  [[ -n "${prompt//[[:space:]]/}" ]] \
    || die "nothing to ask — usage: $(basename "$0") prompt <text>"

  ensure_box
  mkdir -p "$LOG_DIR"
  use_branch

  build_agent_flags "$prompt"
  local out; out=$(run_agent)
  local status=$?

  printf '%s\n' "$out" > "$LOG_DIR/prompt.json"

  [[ $status -ne 0 ]] && die "$AGENT exited $status — see $LOG_DIR/prompt.json"
  agent_failed "$out" && die "$AGENT reported an error — see $LOG_DIR/prompt.json"

  printf '%s\n' "$(agent_text "$out")"
  in_box git log --oneline -1
  extract
}
# afk loop - Runs agent in sandbox with $PROMPT_FILE as instructions
cmd_loop() {
  ensure_box
  mkdir -p "$LOG_DIR"
  use_branch

  local i
  for i in $(seq 1 "$MAX_ITERATIONS"); do
    printf '\n'; log "iteration $i / $MAX_ITERATIONS"

    # Re-read the prompt file each loop iteration
    load_prompt

    # Build agent's profile flags
    build_agent_flags "$PROMPT"

    local before; before=$(head_sha)
    local out; out=$(run_agent)
    local status=$?

    printf '%s\n' "$out" > "$LOG_DIR/iter-$i.json"

    if [[ $status -ne 0 ]]; then
      warn "$AGENT exited $status — see $LOG_DIR/iter-$i.json"
      break
    fi

    # Break when agent reports an error - based on agent's profile agent_failed
    if agent_failed "$out"; then
      warn "$AGENT reported an error — see $LOG_DIR/iter-$i.json"
      break
    fi

    local text
    text=$(agent_text "$out")

    printf '%s\n' "$text"

    # Break when agent reports done sentinel
    if [[ "$text" == *"$DONE_SENTINEL"* ]]; then
      log "sentinel reached — finished after $i iterations"
      break
    fi

    # Break when agent has not committed any work - probably stuck
    local after; after=$(head_sha)
    if [[ "$STOP_ON_NO_COMMIT" == "1" && "$before" == "$after" ]]; then
      warn "no commit this iteration — likely stuck; stopping"
      warn "inspect with: $(basename "$0") shell"
      break
    fi
    in_box git log --oneline -1

    # Sleep between iterations
    [[ "$SLEEP_BETWEEN" -gt 0 ]] && sleep "$SLEEP_BETWEEN"
  done

  extract
}

# extract - streams the branch out as a git bundle over `sbx exec`.
#
# Clone mode also adds a `sandbox-<name>` git remote to the host repo, but sbx
# deletes that remote whenever the sandbox stops after the agent stops.
# sbx exec always works — it starts a stopped sandbox — and its status chatter goes to
# stderr, so the bundle on stdout stays intact.
extract() {
  [[ "$USE_CLONE" == "1" ]] || { log "not clone mode — work is already on disk"; return; }

  local bundle="$LOG_DIR/$BRANCH.bundle"
  log "fetching $BRANCH out of the sandbox"
  in_box git bundle create - "$BRANCH" 2>/dev/null > "$bundle" \
    || { warn "could not bundle $BRANCH out of the sandbox"; return; }

  # Only keep bundle when the fetch failed and it is the sole copy on the host.
  git fetch "$bundle" "$BRANCH:$BRANCH" 2>/dev/null \
    && { rm -f "$bundle"; log "fetched. review with: git log --oneline $BRANCH"; return; }

  # Never force merge back on the host — the sandbox's work is in the bundle either
  # way, so let the user pick a name and diff the two themselves.
  warn "could not fast-forward $BRANCH — it already exists here and has diverged"
  warn "the sandbox's work is safe in $bundle; get it with:"
  warn "  git fetch $bundle $BRANCH:$BRANCH-sandbox"
}

# ==============================================================================

usage() {
  local me; me="$(basename "$0")"
  cat <<EOF
usage: $me <command>

  init            write $CONFIG_FILE for this repository, so afk knows which
                  sandbox and agent this project uses, and git-ignore \$LOG_DIR
  config          show every effective setting and where it came from
  loop            work through $PROMPT_FILE (instructions + checklist), one item
                  per iteration, until it is done
  prompt <text>   run the agent once on that prompt instead of $PROMPT_FILE,
                  then fetch the branch back. With no <text>, the prompt is read
                  from stdin: $(basename "$0") prompt < brief.md
  smoke           verify sandbox + auth + network + model. Do this first.
  shell           drop into the sandbox to poke around
  remove          destroy the sandbox so the next run starts clean

Runs against the repository you are currently in — cd there first. Settings come
from the environment, then $CONFIG_FILE, then built-in defaults:
MAX_ITERATIONS=3 MODEL=sonnet $me loop — see the README.
EOF
}

# No bare default: `loop` starts a long, unattended run, so it has to be asked
# for by name rather than being what you get for typing the command alone.
# Help works without the dependencies installed, so it comes first.
case "${1:-}" in
  ""|help|-h|--help) apply_defaults; usage; exit 0 ;;
esac

# Order matters here, and this is the whole of it: find the repository before
# reading its settings, read them before the defaults can paper over them, and
# resolve all of it before picking the agent profile — which reads $AGENT, and
# so cannot run at load time any more.
need git
resolve_repo
log "repository: $REPO"

snapshot_env
load_repo_config
apply_defaults
report_config

cmd="$1"; shift

# Neither of these talks to a sandbox, so neither needs sbx or jq installed —
# `init` in particular is the first thing you run in a new repository.
case "$cmd" in
  init)   cmd_init;   exit 0 ;;
  config) cmd_config; exit 0 ;;
esac

need sbx; need jq
select_agent_profile

case "$cmd" in
  loop)   cmd_loop   ;;
  prompt) cmd_prompt "$@" ;;
  smoke)  cmd_smoke  ;;
  shell)  cmd_shell  ;;
  remove) cmd_remove ;;
  reset)  die "no such command: reset — it is now \`$(basename "$0") remove\`" ;;
  *)      usage >&2; die "unknown command: $cmd" ;;
esac

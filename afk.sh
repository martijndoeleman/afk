#!/usr/bin/env bash
#
# afk.sh — run a coding agent headlessly, over and over, inside one
# long-lived sbx sandbox. Defaults to Claude Code; see AGENT.
#
# Each iteration is a fresh process, so the context window starts empty every
# time. Continuity comes from files + git history inside the sandbox's clone,
# not from conversation history — primarily from $PROMPT_FILE, the single input:
# one file that both describes the task items and says how to work through
# them. It is sent to the agent verbatim as the prompt, every iteration.
#
# Every setting below can be overridden from the environment, e.g.:
#   MAX_ITERS=2 BOX=test-box afk loop
#
# Subcommands:
#   afk loop            # run the loop
#   afk prompt <text>   # run the agent once on an ad-hoc prompt
#   afk smoke           # verify sandbox + auth + network, no real work
#   afk shell           # drop into the sandbox to poke around
#   afk remove          # destroy the sandbox and start clean
#
# Installed as `afk` by install.sh; run it as ./afk.sh if you'd rather not
# install it. Both take the same subcommands.

set -uo pipefail

# ==============================================================================
# CONFIG — adjust per project / task
# ==============================================================================

# --- sandbox ---
BOX="${BOX:-afk}"                   # sandbox name (one per project)
# Used both as the sbx agent type (sbx create <AGENT>) and as the CLI to run
# inside the box. sbx offers claude, codex, copilot, cursor, docker-agent,
# droid, gemini, kiro, opencode, shell. Swapping this alone is not enough —
# see AGENT_FLAGS and the result parsing in cmd_loop, both of which still
# assume Claude Code's flags and JSON schema.
AGENT="${AGENT:-claude}"
# There is deliberately no WORKSPACE setting. afk works on the repository you
# run it from, so the mounted directory, the branch fetch target and LOG_DIR are
# the same place by construction. When they could differ, the only thing a
# WORKSPACE override bought you was mounting one repo and delivering the results
# to another. To work on a different repo, cd to it — see resolve_repo.
USE_CLONE="${USE_CLONE:-1}"            # 1 = private in-VM clone, 0 = mount directly
BRANCH="${BRANCH:-agent-loop}"         # branch the agent commits to
CPUS="${CPUS:-0}"                      # 0 = auto (all host CPUs)
MEMORY="${MEMORY:-}"                   # e.g. 8g; empty = sbx default

# --- loop control ---
MAX_ITERS="${MAX_ITERS:-10}"           # hard cap; always set one
MAX_TURNS="${MAX_TURNS:-40}"           # agentic turns per iteration
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"    # seconds between iterations
STOP_ON_NO_COMMIT="${STOP_ON_NO_COMMIT:-1}"  # bail if an iteration commits nothing

# --- the task ---
# $PROMPT_FILE is the only input. It is the prompt: its prose says how to work on
# this repository, its checklist says what to work on, and the loop sends it to
# the agent verbatim, every iteration. There is no separate prompt setting —
# instructions and task list are edited, reviewed and committed together, and
# two inputs only gave them a way to disagree.
#
# Because it is used verbatim, nothing in it is interpolated: it has to spell
# out $DONE_SENTINEL itself, or the loop can never detect that the work is
# finished. load_prompt checks that before spending anything.
PROMPT_FILE="${PROMPT_FILE:-PROMPT.md}"
DONE_SENTINEL="${DONE_SENTINEL:-ALL_DONE}"
MODEL="${MODEL:-}"                     # empty = the agent profile's default (claude: opus)
EFFORT="${EFFORT:-medium}"             # low | medium | high | xhigh | max; empty = default

# --- output ---
LOG_DIR="${LOG_DIR:-./.afk-logs}"

# ==============================================================================
# INTERNALS
# ==============================================================================

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing dependency: $1"; }

# The repository afk operates on: the one containing the current directory.
# We move to its root and stay there, so everything downstream — the directory
# mounted into the VM, the `git fetch` that brings the branch back, LOG_DIR,
# and PROMPT_FILE — resolves against one path with no way for them to disagree.
#
# Root, not the current directory: running from a subdirectory would otherwise
# mount that subdirectory, and `sbx create --clone` needs a git root to clone.
#
# The path must be absolute AND correctly cased: macOS is case-insensitive but
# the Linux VM is not, so mounting /Users/me/developer when the real directory
# is /Users/me/Developer makes sandbox creation fail. /bin/pwd (not the bash
# builtin, which just echoes $PWD back) calls getcwd() and returns the real one.
REPO=""
resolve_repo() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository — cd into the repo you want worked on"
  [[ -n "$top" ]] || die "no repository root here (a bare repo?) — cd into a working tree"
  REPO="$(cd "$top" && /bin/pwd -P)" || die "cannot enter repository root: $top"
  cd "$REPO" || die "cannot enter repository root: $REPO"
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

# NOTE: do NOT add `-u root` here. Claude Code refuses to run with
# --dangerously-skip-permissions as root, and you don't need root anyway.
in_box() { sbx exec "$BOX" "$@"; }

head_sha() { in_box git rev-parse HEAD 2>/dev/null | tr -d '\r\n'; }

# The prompt is $PROMPT_FILE, read from inside the sandbox rather than from the
# host: in clone mode the agent reads and rewrites the VM's committed copy, so
# reading that same copy is what stops the prompt describing a task list the
# agent cannot see. It also catches the common mistake — editing PROMPT.md and
# forgetting to commit — as an empty or stale prompt at iteration 1, before any
# money is spent.
PROMPT=""
SENTINEL_WARNED=""
load_prompt() {
  in_box test -f "$PROMPT_FILE" \
    || die "$PROMPT_FILE not found in the sandbox workspace — commit it, then \`$(basename "$0") remove\`"
  PROMPT="$(in_box cat "$PROMPT_FILE")" || die "could not read $PROMPT_FILE from the sandbox"
  [[ -n "${PROMPT//[[:space:]]/}" ]] || die "$PROMPT_FILE is empty — it is the prompt, so there is nothing to run"
  # Re-read every iteration, so warn once rather than on every one.
  if [[ -z "$SENTINEL_WARNED" && "$PROMPT" != *"$DONE_SENTINEL"* ]]; then
    SENTINEL_WARNED=1
    warn "$PROMPT_FILE never mentions $DONE_SENTINEL — the loop can only stop on MAX_ITERS"
  fi
}

# ==============================================================================
# AGENT PROFILES
# ==============================================================================
#
# Agents differ in three ways, and only these three: how to invoke them
# headlessly, how to recover the final assistant message, and whether they
# report a cost. Everything below this section is agent-neutral.
#
# Each profile defines:
#   build_agent_flags <prompt> <max_turns>   -> sets the AGENT_FLAGS array
#   agent_text  <raw_output>                 -> prints the final message
#   agent_cost  <raw_output>                 -> prints a dollar amount, or 0
#   agent_failed <raw_output>                -> true if the run errored

CODEX_LAST_MSG="/tmp/afk-last-message.txt"

case "$AGENT" in
  claude)
    MODEL="${MODEL:-opus}"
    build_agent_flags() {
      AGENT_FLAGS=(
        -p "$1"
        --dangerously-skip-permissions   # ok here: the microVM is the boundary
        --max-turns "$2"
        --output-format json
      )
      [[ -n "$MODEL" ]]  && AGENT_FLAGS+=(--model "$MODEL")
      [[ -n "$EFFORT" ]] && AGENT_FLAGS+=(--effort "$EFFORT")
      return 0
    }
    agent_text()   { jq -r '.result // empty'        <<<"$1"; }
    agent_cost()   { jq -r '.total_cost_usd // 0'    <<<"$1"; }
    agent_failed() { [[ "$(jq -r '.is_error // false' <<<"$1")" == "true" ]]; }
    ;;

  codex)
    # `codex exec` is the non-interactive entry point, and it is shaped quite
    # differently from Claude Code:
    #   - --json emits a stream of JSONL events, not one result object, so the
    #     final message is recovered from --output-last-message instead.
    #   - there is no --max-turns equivalent, so $2 is ignored and MAX_TURNS
    #     has no effect. MAX_ITERS is your only bound.
    #   - reasoning effort is a config override, not a flag.
    #   - no cost is reported, so the running total stays at 0.
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
    agent_cost()   { printf '0'; }
    # turn.failed, not "type":"error" — codex emits error events for transient
    # things it then recovers from (websocket reconnects), so matching those
    # would fail runs that actually went on to succeed.
    agent_failed() { grep -q '"type":"turn.failed"' <<<"$1"; }
    ;;

  *)
    die "no profile for AGENT=$AGENT (known: claude, codex)"
    ;;
esac

# ==============================================================================
# SUBCOMMANDS
# ==============================================================================

cmd_smoke() {
  ensure_box
  log "workspace inside sandbox:"; in_box pwd
  log "git status:";               in_box git status --short --branch
  log "$AGENT version:";           in_box "$AGENT" --version
  # Same profile, model and effort as the loop, so a bad --model surfaces here
  # for one cheap turn rather than on every iteration of a long run. (Claude
  # Code silently ignores a bad --effort, so this cannot check that.)
  log "round-trip test (checks auth + network + model):"
  build_agent_flags "Reply with exactly: PONG" 1
  local out; out=$(in_box "$AGENT" "${AGENT_FLAGS[@]}" </dev/null)
  agent_failed "$out" && { printf '%s\n' "$out" | tail -5; die "round-trip failed"; }
  printf '%s\n' "$(agent_text "$out")"
  log "cost \$$(agent_cost "$out")"
  log "smoke test passed"
}

cmd_shell() { ensure_box; sbx exec -it "$BOX" bash; }

cmd_remove() {
  log "removing sandbox $BOX"
  sbx rm -f "$BOX" 2>/dev/null || true
  log "gone. next run will create it fresh."
}

# Switch to $BRANCH, creating it only if it is missing. Deliberately NOT
# `checkout -B`, which force-resets the branch to HEAD and would silently
# discard the commits a previous run left on it.
use_branch() {
  in_box git checkout "$BRANCH" 2>/dev/null \
    || in_box git checkout -b "$BRANCH" \
    || die "could not switch to branch $BRANCH"
}

# One agent run on a prompt you pass in, instead of the whole $PROMPT_FILE loop.
# Everything else is the loop's machinery: same sandbox, same branch, and the
# same bundle fetch at the end, so whatever it commits comes back the same way.
# For asking a question rather than changing anything, nothing is committed and
# extract is a no-op beyond re-fetching the branch as it was.
cmd_prompt() {
  local prompt="$*"
  # No arguments and something piped in: take the prompt from stdin, so
  # `afk prompt < brief.md` works without shell-quoting a multi-line file.
  if [[ -z "$prompt" && ! -t 0 ]]; then prompt="$(cat)"; fi
  [[ -n "${prompt//[[:space:]]/}" ]] \
    || die "nothing to ask — usage: $(basename "$0") prompt <text>"

  ensure_box
  mkdir -p "$LOG_DIR"
  use_branch

  build_agent_flags "$prompt" "$MAX_TURNS"
  local out; out=$(in_box "$AGENT" "${AGENT_FLAGS[@]}" </dev/null)
  local status=$?

  printf '%s\n' "$out" > "$LOG_DIR/prompt.json"

  [[ $status -ne 0 ]] && die "$AGENT exited $status — see $LOG_DIR/prompt.json"
  agent_failed "$out" && die "$AGENT reported an error — see $LOG_DIR/prompt.json"

  printf '%s\n' "$(agent_text "$out")"
  log "cost \$$(agent_cost "$out")"
  in_box git log --oneline -1
  extract
}

cmd_loop() {
  ensure_box
  mkdir -p "$LOG_DIR"
  use_branch

  local total=0 i
  for i in $(seq 1 "$MAX_ITERS"); do
    printf '\n'; log "iteration $i / $MAX_ITERS"

    # Re-read the file each time: the agent ticks items off in it, so the
    # previous iteration's edits are exactly what tells this fresh, empty
    # context what is left to do.
    load_prompt
    build_agent_flags "$PROMPT" "$MAX_TURNS"

    local before; before=$(head_sha)
    # </dev/null or codex reads the inherited stdin and appends it to the
    # prompt; harmless for claude, which takes the prompt as an argument.
    local out; out=$(in_box "$AGENT" "${AGENT_FLAGS[@]}" </dev/null)
    local status=$?

    printf '%s\n' "$out" > "$LOG_DIR/iter-$i.json"

    if [[ $status -ne 0 ]]; then
      warn "$AGENT exited $status — see $LOG_DIR/iter-$i.json"
      break
    fi

    # Belt and braces. API failures (bad model, 429, overloaded) do exit
    # nonzero and are caught above, but this reports what actually went wrong
    # instead of a bare exit code, and covers any case that exits 0 anyway.
    if agent_failed "$out"; then
      warn "$AGENT reported an error — see $LOG_DIR/iter-$i.json"
      break
    fi

    local text cost
    text=$(agent_text "$out")
    cost=$(agent_cost "$out")
    total=$(awk "BEGIN{printf \"%.4f\", $total + $cost}")

    printf '%s\n' "$text"
    log "cost \$$cost  |  running total \$$total"

    if [[ "$text" == *"$DONE_SENTINEL"* ]]; then
      log "sentinel reached — finished after $i iterations"
      break
    fi

    local after; after=$(head_sha)
    if [[ "$STOP_ON_NO_COMMIT" == "1" && "$before" == "$after" ]]; then
      warn "no commit this iteration — likely stuck; stopping"
      warn "inspect with: $(basename "$0") shell"
      break
    fi
    in_box git log --oneline -1

    [[ "$SLEEP_BETWEEN" -gt 0 ]] && sleep "$SLEEP_BETWEEN"
  done

  log "total spend this run: \$$total"
  extract
}

# Stream the branch out as a git bundle over `sbx exec`.
#
# Clone mode also adds a `sandbox-<name>` git remote to the host repo, but sbx
# deletes that remote whenever the sandbox stops and does not restore it on
# restart, so fetching from it works only until the first stop. exec always
# works — it starts a stopped sandbox first — and its status chatter goes to
# stderr, so the bundle on stdout stays intact.
extract() {
  [[ "$USE_CLONE" == "1" ]] || { log "not clone mode — work is already on disk"; return; }

  local bundle="$LOG_DIR/$BRANCH.bundle"
  log "fetching $BRANCH out of the sandbox"
  in_box git bundle create - "$BRANCH" 2>/dev/null > "$bundle" \
    || { warn "could not bundle $BRANCH out of the sandbox"; return; }

  # On success the commits are in the repo, so the bundle is just a duplicate.
  # Only keep it when the fetch failed and it is the sole copy on the host.
  git fetch "$bundle" "$BRANCH:$BRANCH" 2>/dev/null \
    && { rm -f "$bundle"; log "fetched. review with: git log --oneline $BRANCH"; return; }

  # Almost always: $BRANCH already exists here and has diverged from the
  # sandbox's copy. Never force — the sandbox's work is in the bundle either
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

  loop            work through $PROMPT_FILE (instructions + checklist), one item
                  per iteration, until it is done
  prompt <text>   run the agent once on that prompt (or on stdin) instead of
                  $PROMPT_FILE, then fetch the branch back
  smoke           verify sandbox + auth + network + model. Do this first.
  shell           drop into the sandbox to poke around
  remove          destroy the sandbox so the next run starts clean

Runs against the repository you are currently in — cd there first. Settings are
environment variables, e.g. MAX_ITERS=3 MODEL=sonnet $me loop — see the README.
EOF
}

# No bare default: `loop` starts a long, billable run, so it has to be asked
# for by name rather than being what you get for typing the command alone.
# Help works without the dependencies installed, so it comes first.
case "${1:-}" in
  ""|help|-h|--help) usage; exit 0 ;;
esac

need sbx; need jq; need git; need awk

resolve_repo
log "repository: $REPO"

cmd="$1"; shift
case "$cmd" in
  loop)   cmd_loop   ;;
  prompt) cmd_prompt "$@" ;;
  smoke)  cmd_smoke  ;;
  shell)  cmd_shell  ;;
  remove) cmd_remove ;;
  reset)  die "no such command: reset — it is now \`$(basename "$0") remove\`" ;;
  *)      usage >&2; die "unknown command: $cmd" ;;
esac

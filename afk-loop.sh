#!/usr/bin/env bash
#
# afk-loop.sh — run a coding agent headlessly, over and over, inside one
# long-lived sbx sandbox. Defaults to Claude Code; see AGENT.
#
# Each iteration is a fresh process, so the context window starts empty every
# time. Continuity comes from files + git history inside the sandbox's clone,
# not from conversation history.
#
# Every setting below can be overridden from the environment, e.g.:
#   MAX_ITERS=2 BOX=test-box ./afk-loop.sh
#
# Subcommands:
#   ./afk-loop.sh smoke    # verify sandbox + auth + network, no real work
#   ./afk-loop.sh shell    # drop into the sandbox to poke around
#   ./afk-loop.sh reset    # destroy the sandbox and start clean
#   ./afk-loop.sh          # run the loop

set -uo pipefail

# ==============================================================================
# CONFIG — adjust per project / task
# ==============================================================================

# --- sandbox ---
BOX="${BOX:-afk-loop}"              # sandbox name (one per project)
# Used both as the sbx agent type (sbx create <AGENT>) and as the CLI to run
# inside the box. sbx offers claude, codex, copilot, cursor, docker-agent,
# droid, gemini, kiro, opencode, shell. Swapping this alone is not enough —
# see AGENT_FLAGS and the result parsing in cmd_loop, both of which still
# assume Claude Code's flags and JSON schema.
AGENT="${AGENT:-claude}"
WORKSPACE="${WORKSPACE:-.}"            # host dir to mount as the workspace
# Must be absolute AND correctly cased: macOS is case-insensitive but the Linux
# VM is not, so mounting /Users/me/developer when the real directory is
# /Users/me/Developer makes sandbox creation fail. /bin/pwd (not the bash
# builtin, which just echoes $PWD back) calls getcwd() and returns the real one.
WORKSPACE="$(cd "$WORKSPACE" && /bin/pwd -P)" || { echo "no such directory: $WORKSPACE" >&2; exit 1; }
USE_CLONE="${USE_CLONE:-1}"            # 1 = private in-VM git clone, 0 = mount directly
BRANCH="${BRANCH:-agent-loop}"         # branch the agent commits to
CPUS="${CPUS:-0}"                      # 0 = auto (all host CPUs)
MEMORY="${MEMORY:-}"                   # e.g. 8g; empty = sbx default

# --- loop control ---
MAX_ITERS="${MAX_ITERS:-10}"           # hard cap; always set one
MAX_TURNS="${MAX_TURNS:-40}"           # agentic turns per iteration
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0}"    # seconds between iterations
STOP_ON_NO_COMMIT="${STOP_ON_NO_COMMIT:-1}"  # bail if an iteration commits nothing

# --- the task ---
TASK_FILE="${TASK_FILE:-TASKS.md}"
DONE_SENTINEL="${DONE_SENTINEL:-ALL_DONE}"
MODEL="${MODEL:-}"                     # empty = the agent profile's default (claude: opus)
EFFORT="${EFFORT:-medium}"             # low | medium | high | xhigh | max; empty = default

PROMPT="${PROMPT:-$(cat <<EOF
Read ${TASK_FILE}. Pick the first item not marked [x] and complete it.
Mark it [x] and commit your work with a descriptive message.
Do exactly ONE item, then stop.
If every item is already [x], reply with exactly: ${DONE_SENTINEL}
EOF
)}"

# Optional: read the prompt from a file instead, e.g. PROMPT_FILE=prompt.md.
# Read on the host, so the file does not need to exist inside the sandbox. Its
# contents are used verbatim — unlike the default above, ${TASK_FILE} and
# ${DONE_SENTINEL} are NOT interpolated, so write the sentinel out in full or
# the loop will never detect that the work is finished.
PROMPT_FILE="${PROMPT_FILE:-}"
if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT="$(cat "$PROMPT_FILE")" || { echo "cannot read PROMPT_FILE: $PROMPT_FILE" >&2; exit 1; }
  [[ "$PROMPT" == *"$DONE_SENTINEL"* ]] \
    || echo "warning: $PROMPT_FILE never mentions $DONE_SENTINEL — the loop can only stop on MAX_ITERS" >&2
fi

# --- output ---
LOG_DIR="${LOG_DIR:-./.afk-logs}"

# ==============================================================================
# INTERNALS
# ==============================================================================

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing dependency: $1"; }

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
  args+=("$AGENT" "$WORKSPACE")
  sbx create "${args[@]}" || die "sandbox creation failed"
}

# NOTE: do NOT add `-u root` here. Claude Code refuses to run with
# --dangerously-skip-permissions as root, and you don't need root anyway.
in_box() { sbx exec "$BOX" "$@"; }

head_sha() { in_box git rev-parse HEAD 2>/dev/null | tr -d '\r\n'; }

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

cmd_reset() {
  log "removing sandbox $BOX"
  sbx rm -f "$BOX" 2>/dev/null || true
  log "gone. next run will create it fresh."
}

cmd_loop() {
  ensure_box
  mkdir -p "$LOG_DIR"

  # Switch to $BRANCH, creating it only if it is missing. Deliberately NOT
  # `checkout -B`, which force-resets the branch to HEAD and would silently
  # discard the commits a previous run left on it.
  in_box git checkout "$BRANCH" 2>/dev/null \
    || in_box git checkout -b "$BRANCH" \
    || die "could not switch to branch $BRANCH"
  in_box test -f "$TASK_FILE" || die "$TASK_FILE not found in the sandbox workspace"

  build_agent_flags "$PROMPT" "$MAX_TURNS"

  local total=0 i
  for i in $(seq 1 "$MAX_ITERS"); do
    printf '\n'; log "iteration $i / $MAX_ITERS"

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
      warn "inspect with: ./afk-loop.sh shell"
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

need sbx; need jq; need git; need awk

case "${1:-loop}" in
  smoke) cmd_smoke ;;
  shell) cmd_shell ;;
  reset) cmd_reset ;;
  loop)  cmd_loop  ;;
  *)     die "unknown command: $1 (use: loop | smoke | shell | reset)" ;;
esac

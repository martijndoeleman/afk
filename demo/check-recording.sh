#!/usr/bin/env bash
#
# check-recording.sh — did the recorded session actually do what the tape says?
#
# Run straight after `vhs demo/demo.tape`. VHS types commands at a terminal; it
# does not check that any of them ran. If a Wait matches early, VHS types the
# next command into a terminal that is still busy and the input is swallowed —
# and a still frame of that looks almost identical to a good take. These checks
# read the side effects instead, which cannot lie.
#
#   ./demo/check-recording.sh
#
# Exits non-zero if the take is bad, so you know to re-record before spending
# time watching frames.

set -uo pipefail

DEMO="/tmp/afk-demo"
GIF="demo/afk.gif"
fail=0

ok()   { printf '\033[1;32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '\033[1;31mFAIL\033[0m  %s\n' "$*"; fail=1; }

check() { [[ -e "$1" ]] && ok "$2" || bad "$3"; }

check "$DEMO/.afkrc" \
  "afk init ran — .afkrc written" \
  ".afkrc missing — init never executed (typed into a busy terminal?)"

if grep -q '^MAX_ITERATIONS=3' "$DEMO/.afkrc" 2>/dev/null; then
  ok "MAX_ITERATIONS=3 frozen from the environment"
else
  bad "MAX_ITERATIONS not frozen — the config step will show a default instead"
fi

check "$DEMO/.afk-logs/prompt.json" \
  "afk prompt ran" \
  "no prompt.json — the ad-hoc run did not happen"

check "$DEMO/.afk-logs/iter-3.json" \
  "afk loop reached iteration 3 (the sentinel one)" \
  "loop did not reach iteration 3 — recording may be cut short"

# Captured rather than piped into `grep -q`: grep exits on the first line, git
# takes SIGPIPE, and `pipefail` reports the whole pipeline as failed.
head_line="$(git -C "$DEMO" log --oneline -1 afk-agent 2>/dev/null)"
if [[ -n "$head_line" ]]; then
  ok "work came back on afk-agent: $head_line"
else
  bad "nothing on afk-agent — the extract step did not land"
fi

if [[ -s "$GIF" ]]; then
  ok "$GIF written ($(du -h "$GIF" | cut -f1), $(ffprobe -v error \
      -show_entries format=duration -of default=nw=1:nk=1 "$GIF" 2>/dev/null)s)"
else
  bad "$GIF missing or empty"
fi

exit "$fail"

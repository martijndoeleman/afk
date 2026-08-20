#!/usr/bin/env bash
#
# setup-demo.sh — build the throwaway repository the README recording is made in.
#
# The point is that nothing on screen can identify whoever recorded it. Recording
# in this repo would put `/Users/<you>/...` on the first line of output, because
# afk logs the repository path it resolved. So the demo runs somewhere neutral,
# with its own git identity.
#
#   ./demo/setup-demo.sh      # (re)create /tmp/afk-demo
#   vhs demo/demo.tape        # record, writing demo/afk.gif
#
# Deliberately does NOT write .afkrc: the recording opens with `afk init`, which
# refuses to overwrite one. Nor does it pin BOX — the sandbox name in the GIF is
# the one afk derives from the directory, which is what a viewer would get.
#
# Destroys and recreates the demo directory, so it is safe to run repeatedly.

set -euo pipefail

DEMO="/tmp/afk-demo"
BOX="afk-demo"

# The sandbox holds its own clone, so a leftover one from an earlier recording
# still has the work list ticked off and the agent would answer ALL_DONE on the
# first iteration. Destroy it too, or the recording is not reproducible.
if command -v sbx >/dev/null; then
  sbx rm -f "$BOX" >/dev/null 2>&1 || true
fi

rm -rf "$DEMO"
mkdir -p "$DEMO"
cd "$DEMO"

git init -q -b main

# Local, not global: the recording must not carry the recorder's name or address.
git config user.name  "dev"
git config user.email "dev@example.com"

# Something small and real for the agent to change, so the run in the recording
# is a genuine edit with a genuine diff rather than a toy.
cat > hello.sh <<'HELLO'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  greet) printf 'hello, %s\n' "${2:-world}" ;;
  *)     printf 'usage: hello.sh greet [name]\n' >&2; exit 1 ;;
esac
HELLO
chmod +x hello.sh

# Short on purpose: the whole list has to fit in the recording area, and each
# item has to be small enough that an iteration is over in a minute or so. The
# brevity instruction is there for the same reason — an agent that writes six
# paragraphs back scrolls the interesting part off screen.
cat > PROMPT.md <<'PROMPT'
# hello.sh — work list

Do one unchecked item per run, commit it, and tick its box in this file.
Keep your reply to a single short line.
When every box is ticked, reply with ALL_DONE.

- [ ] Add a `--version` flag printing `hello.sh 0.1.0`
- [ ] Add a `--help` flag printing the usage line
PROMPT

git add -A
git commit -qm "hello.sh, and a list of things it is missing"

printf 'demo repository ready at %s\n' "$DEMO"

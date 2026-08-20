#!/usr/bin/env bash
#
# setup-demo.sh — build the throwaway repository the README recording is made in.
#
# Destroys and recreates the demo directory, so it is safe to run repeatedly.
#

set -euo pipefail

DEMO="/tmp/afk-demo"
BOX="afk-demo"

if command -v sbx >/dev/null; then
  sbx rm -f "$BOX" >/dev/null 2>&1 || true
fi

rm -rf "$DEMO"
mkdir -p "$DEMO"
cd "$DEMO"

git init -q -b main
git config user.name  "dev"
git config user.email "dev@example.com"

cat > hello.sh <<'HELLO'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  greet) printf 'hello, %s\n' "${2:-world}" ;;
  *)     printf 'usage: hello.sh greet [name]\n' >&2; exit 1 ;;
esac
HELLO
chmod +x hello.sh

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

afk smoke

printf 'demo repository ready at %s\n' "$DEMO"

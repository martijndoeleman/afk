#!/usr/bin/env bash
#
# install.sh — symlink afk.sh onto your PATH as `afk`, so you can run
# it from inside any repository by name:
#
#   cd ~/code/my-project && BOX=my-project afk loop
#
# A symlink, not a copy: `git pull` in this repo updates the installed command.
# The script resolves its own real path, so it still finds everything it needs.
#
#   ./install.sh                      # install to the first writable PATH dir
#   PREFIX=~/bin ./install.sh         # install somewhere specific
#   FORCE=1 ./install.sh              # overwrite whatever is already there
#   ./install.sh uninstall            # remove the symlink
#
# Uninstalling by hand is just: rm <the path it printed>

set -euo pipefail

NAME="afk"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)/afk.sh"

log()  { printf '\033[1;34m>>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC" ]] || die "cannot find afk.sh next to install.sh (looked in ${SRC%/*})"

# Pick an install dir. An explicit PREFIX wins; otherwise take the first
# directory that is both on PATH and writable, so the common case needs no sudo.
choose_prefix() {
  local dir
  for dir in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
    case ":$PATH:" in *":$dir:"*) [[ -w "$dir" ]] && { printf '%s' "$dir"; return; } ;; esac
  done
  # Nothing suitable on PATH: fall back to ~/.local/bin and tell them to add it.
  printf '%s' "$HOME/.local/bin"
}

PREFIX="${PREFIX:-$(choose_prefix)}"
PREFIX="${PREFIX/#\~/$HOME}"
DEST="$PREFIX/$NAME"

if [[ "${1:-install}" == "uninstall" ]]; then
  [[ -e "$DEST" || -L "$DEST" ]] || die "nothing installed at $DEST"
  [[ -L "$DEST" ]] || die "$DEST is not a symlink — refusing to remove it"
  rm "$DEST"
  log "removed $DEST"
  exit 0
fi

mkdir -p "$PREFIX" || die "cannot create $PREFIX"
[[ -w "$PREFIX" ]] || die "$PREFIX is not writable — try PREFIX=~/.local/bin ./install.sh"

# Don't clobber someone else's file. An existing symlink to our own script is
# just a re-install, so that one is always fine to replace.
if [[ -e "$DEST" || -L "$DEST" ]]; then
  if [[ "${FORCE:-0}" != "1" && "$(readlink "$DEST" 2>/dev/null)" != "$SRC" ]]; then
    die "$DEST already exists and is not a link to $SRC — rerun with FORCE=1 to replace it"
  fi
  rm -f "$DEST"
fi

chmod +x "$SRC"
ln -s "$SRC" "$DEST"
log "installed $DEST -> $SRC"

case ":$PATH:" in
  *":$PREFIX:"*) log "run it from any repo: cd ~/code/my-project && BOX=my-project $NAME smoke" ;;
  *) warn "$PREFIX is not on your PATH. Add this to your shell profile:"
     warn "  export PATH=\"$PREFIX:\$PATH\"" ;;
esac

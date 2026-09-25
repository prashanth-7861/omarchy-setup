#!/usr/bin/env bash
#
# omarchy-set-nano-editor.sh
#
# Make nano the default text editor (replacing vim/neovim) on an Omarchy
# system. Idempotent — safe to run repeatedly.
#
# What it does:
#   1. Sets the Omarchy editor state file
#      (~/.local/state/omarchy/defaults/editor) to "nano", which
#      omarchy-launch-editor / launcher / menu shortcuts all read.
#   2. Exports EDITOR, VISUAL, SUDO_EDITOR=nano in ~/.bashrc, ~/.bash_profile
#      and ~/.profile, inside an idempotent <<<marker>>> block.
#   3. Sets git core.editor=nano (global).
#   4. Writes ~/.config/fish/conf.d/editor.fish for fish shells.
#
# Usage:
#   bash omarchy-set-nano-editor.sh            # apply
#   bash omarchy-set-nano-editor.sh --revert   # restore previous editor

set -euo pipefail

MARKER_TOP="# >>> omarchy-nano-editor >>>"
MARKER_BOT="# <<< omarchy-nano-editor <<<"
EXPORT_BLOCK='export EDITOR=nano
export VISUAL=nano
export SUDO_EDITOR=nano'

STATE_FILE="$HOME/.local/state/omarchy/defaults/editor"
FISH_CONF="$HOME/.config/fish/conf.d/editor.fish"
RC_FILES=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")

usage() {
  echo "Usage: bash $0 [--revert]"
  echo "  --revert   remove the nano overrides and restore the previous editor"
  exit "${1:-0}"
}

# Remove any previously-installed marker block from a file.
strip_marker_block() {
  local file="$1" tmp
  [[ -f "$file" ]] || return 0
  tmp="${file}.omarchy-nano-editor.tmp"
  awk -v t="$MARKER_TOP" -v b="$MARKER_BOT" '
    $0==t { skip=1; next }
    $0==b { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Make sure a file carries the marker block exactly once.
apply_marker_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  strip_marker_block "$file"
  printf '\n%s\n%s\n%s\n' "$MARKER_TOP" "$EXPORT_BLOCK" "$MARKER_BOT" >> "$file"
}

do_apply() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'nano\n' > "$STATE_FILE"

  for rc in "${RC_FILES[@]}"; do
    apply_marker_block "$rc"
  done

  git config --global core.editor nano

  mkdir -p "$(dirname "$FISH_CONF")"
  cat > "$FISH_CONF" <<'EOF'
# Use nano as the default editor (managed by omarchy-set-nano-editor.sh)
set -x EDITOR nano
set -x VISUAL nano
set -x SUDO_EDITOR nano
EOF

  echo "nano is now the default editor."
  echo
  echo "Verification (run in a NEW shell):"
  echo "  omarchy default editor           => $(cat "$STATE_FILE")"
  echo "  git config --global core.editor  => was set to nano"
  echo "  echo \$EDITOR                    => nano"
}

do_revert() {
  rm -f "$STATE_FILE"
  for rc in "${RC_FILES[@]}"; do
    strip_marker_block "$rc"
  done
  rm -f "$FISH_CONF"
  if [[ "$(git config --global core.editor 2>/dev/null)" == "nano" ]]; then
    git config --global --unset core.editor
  fi

  echo "Reverted. The editor state file was removed, so Omarchy falls back to"
  echo "its default editor (neovim) for launcher/menu commands."
}

case "${1:-}" in
  ""|apply) do_apply ;;
  --revert|-r) do_revert ;;
  -h|--help) usage ;;
  *) echo "error: unknown argument '$1'" >&2; usage 1 ;;
esac
#!/usr/bin/env bash
# Re-wire the Windows VM mounts so `omarchy-windows-vm launch` can start it.
#
# Root cause: omarchy-windows-vm's assert_mounts_safe() only accepts mount
# leaves whose mode is EXACTLY 700. If something (e.g. the Windows guest or
# Samba's shared-folder handling) sets the setgid bit on $HOME/Windows, the
# shared leaf reads 2700 and every VM start is refused up-front, before Docker
# is ever contacted ("Failed to start Windows VM!", no dockerd events). The
# guest re-applies the bit after every run, so it is not a one-time event.
#
# Usage:
#   omarchy-fix-windows-vm.sh           # clear bits, verify mounts + launcher entry,
#                                       # then launch
#   omarchy-fix-windows-vm.sh --check   # only clear + verify, do not launch
#   omarchy-fix-windows-vm.sh --install # permanently patch /usr/bin/omarchy-windows-vm
#                                       # to tolerate the special bits (mask mode),
#                                       # then verify with --check
#
# --install makes plain `omarchy-windows-vm launch` work WITHOUT this script,
# until `omarchy update` reinstalls the packaged script - then run --install
# again. The mask keeps the owner-only (0700) access check intact while ignoring
# setgid/setuid/sticky, so the shared folder cannot block starts anymore.
#
# Every mode also verifies (and recreates if needed) the launcher entry
# ~/.local/share/applications/windows-vm.desktop - the "Windows VM" icon that
# otherwise reports "Failed to launch" when the mount gate blocks `up`.
set -u

SYSTEM_SCRIPT=/usr/bin/omarchy-windows-vm
LEAVES_BASE="/var/lib/omarchy/windows/mounts/users/$(id -u)"
STORAGE_SRC="$HOME/.windows"
SHARED_SRC="$HOME/Windows"
STORAGE_LEAF="$LEAVES_BASE/storage"
SHARED_LEAF="$LEAVES_BASE/shared"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/windows-vm.desktop"

die() { printf 'omarchy-fix-windows-vm: %s\n' "$*" >&2; exit 1; }

fix_desktop_entry() {
  local dir exec_line
  dir=$(dirname -- "$DESKTOP_FILE")
  mkdir -p "$dir" 2>/dev/null || true
  exec_line=$(grep -m1 '^Exec=' "$DESKTOP_FILE" 2>/dev/null || true)
  if [[ $exec_line == *"omarchy-windows-vm launch"* ]]; then
    echo "OK [desktop] $DESKTOP_FILE"
    return 0
  fi
  cat > "$DESKTOP_FILE" <<'EOF'
[Desktop Entry]
Name=Windows
Comment=Start Windows VM via Docker and connect with RDP
Exec=uwsm app -- omarchy-windows-vm launch
Icon=windows
Terminal=false
Type=Application
Categories=System;Virtualization;
EOF
  chmod 0644 "$DESKTOP_FILE"
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$dir" >/dev/null 2>&1 || true
  echo "REPAIRED [desktop] recreated $DESKTOP_FILE"
}

install_system_patch() {
  [[ -f $SYSTEM_SCRIPT ]] || die "system script not found: $SYSTEM_SCRIPT"
  echo "Applying mount-gate mask patch to $SYSTEM_SCRIPT (root)..."
  pkexec bash -c '
set -e
F=/usr/bin/omarchy-windows-vm
[ -f "$F" ] || exit 1
[ -f "$F.omarchyfix.bak" ] || cp -a "$F" "$F.omarchyfix.bak"
grep -q '\''${mode: -3} == 700'\'' "$F" ||
  sed -i '\''s/\&\& \$mode == 700 \]\]/\&\& ${mode: -3} == 700 ]]/'\'' "$F"
grep -q '\''${storage_mode: -3} != 700'\'' "$F" ||
  sed -i '\''s/if \[\[ \$storage_mode != 700 || \$shared_mode != 700 \]\]; then/if [[ ${storage_mode: -3} != 700 || ${shared_mode: -3} != 700 ]]; then/'\'' "$F"
bash -n "$F"
' || { echo "Could not patch $SYSTEM_SCRIPT (authorization declined?)." >&2; return 1; }
  grep -q '${mode: -3} == 700' "$SYSTEM_SCRIPT" || die "patch verification failed"
  echo "Patched. Plain 'omarchy-windows-vm' now tolerates the setgid bit."
}

for src in "$STORAGE_SRC" "$SHARED_SRC"; do
  [[ -d $src && ! -L $src ]] || die "missing source dir: $src"
done

# Drop setgid/setuid/sticky so mounted_leaf_matches (mode == 700) accepts them.
# `chmod g-s` first: a bare numeric 0700 can leave the sticky group bit in
# place on a directory.
for src in "$SHARED_SRC" "$STORAGE_SRC"; do
  chmod g-s "$src" 2>/dev/null || true
  chmod 0700 "$src" 2>/dev/null || true
done

check_leaf() {
  local stable="$1" src="$2" name="$3"
  local canonical identity actual owner mode layers

  # Missing/unmounted anchors are re-created and bound by the launcher's own
  # prepare_caller_mounts, so defer (SKIP) instead of blocking the launch.
  [[ -d $stable && ! -L $stable ]] || { echo "SKIP [$name]: anchor missing"; return 0; }
  canonical=$(realpath -e -- "$stable" 2>/dev/null) || { echo "SKIP [$name]: cannot resolve"; return 0; }
  [[ $canonical == "$stable" ]] || { echo "FAIL [$name]: canonical mismatch"; return 1; }
  mountpoint -q -- "$stable" 2>/dev/null || { echo "SKIP [$name]: not mounted yet"; return 0; }
  layers=$(awk -v p="$stable" '$5==p{n++} END{print n+0}' /proc/self/mountinfo)
  [[ $layers == 1 ]] || { echo "FAIL [$name]: mount layers=$layers"; return 1; }
  identity=$(stat -Lc '%d:%i' "$src")
  actual=$(stat -Lc '%d:%i' "$stable")
  owner=$(stat -Lc '%u' "$stable")
  mode=$(stat -Lc '%a' "$stable")
  [[ $actual == "$identity" && $owner == "$(id -u)" && $mode == 700 ]] \
    || { echo "FAIL [$name]: identity=$actual want=$identity owner=$owner mode=$mode"; return 1; }
  echo "PASS [$name]"
}

case "${1:-}" in
  --install)
    install_system_patch || exit 1
    ;;&
  --check)
    ;;
esac

ok=1
check_leaf "$STORAGE_LEAF" "$STORAGE_SRC" storage || ok=0
check_leaf "$SHARED_LEAF"  "$SHARED_SRC"  shared  || ok=0
[[ $ok == 1 ]] || die "mount gates not satisfied; Windows VM cannot start safely"

echo "Windows VM mount gates are clean."

fix_desktop_entry

case "${1:-}" in
  --check)
    exit 0
    ;;
  --install)
    exit 0
    ;;
esac

if [[ -x $SYSTEM_SCRIPT ]]; then
  echo "Launching the Windows VM..."
  exec "$SYSTEM_SCRIPT" launch "$@"
fi
die "omarchy-windows-vm not found"
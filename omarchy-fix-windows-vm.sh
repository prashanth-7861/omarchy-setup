#!/usr/bin/env bash
# Re-wire the Windows VM mounts so `omarchy-windows-vm launch` can start it.
#
# Root cause: omarchy-windows-vm's assert_mounts_safe() only accepts mount
# leaves whose mode is EXACTLY 700. If something (e.g. the Windows guest or
# Samba's shared-folder handling) sets the setgid bit on $HOME/Windows, the
# shared leaf reads 2700 and every VM start is refused up-front, before Docker
# is ever contacted ("Failed to start Windows VM!", no dockerd events).
#
# Usage:
#   omarchy-fix-windows-vm.sh           # clear bits, verify mounts, then launch
#   omarchy-fix-windows-vm.sh --check   # only clear + verify, do not launch
set -u

LEAVES_BASE="/var/lib/omarchy/windows/mounts/users/$(id -u)"
STORAGE_SRC="$HOME/.windows"
SHARED_SRC="$HOME/Windows"
STORAGE_LEAF="$LEAVES_BASE/storage"
SHARED_LEAF="$LEAVES_BASE/shared"

die() { printf 'omarchy-fix-windows-vm: %s\n' "$*" >&2; exit 1; }

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

ok=1
check_leaf "$STORAGE_LEAF" "$STORAGE_SRC" storage || ok=0
check_leaf "$SHARED_LEAF"  "$SHARED_SRC"  shared  || ok=0
[[ $ok == 1 ]] || die "mount gates not satisfied; Windows VM cannot start safely"

echo "Windows VM mount gates are clean."

if [[ ${1:-} == "--check" ]]; then
  exit 0
fi

if [[ -x /usr/share/omarchy/bin/omarchy-windows-vm ]]; then
  echo "Launching the Windows VM..."
  exec /usr/share/omarchy/bin/omarchy-windows-vm launch "$@"
fi
die "omarchy-windows-vm not found"
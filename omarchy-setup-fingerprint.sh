#!/usr/bin/env bash
#
# omarchy-setup-fingerprint.sh
#
# Automate fingerprint authentication on any device running Omarchy/Arch:
#   1. Detect the fingerprint reader on the USB bus.
#   2. Classify it and install the matching driver stack.
#   3. Enable the required services.
#   4. Enroll + verify a finger.
#   5. Wire PAM for sudo, polkit, and the Omarchy lock screen.
#
#   Validity / Synaptics readers (138a:0090, 138a:0097, 138a:009d, 06cb:009a)
#     -> python-validity + open-fprintd   (AUR, via yay / omarchy-pkg-aur-add)
#     -> services: open-fprintd, python3-validity (+ suspend hotfix)
#   Standard libfprint readers (most others)
#     -> fprintd + libfprint              (pacman)
#     -> services: fprintd
#
# Requirements: sudo access and a terminal (it prompts for the sudo password,
# may trigger an AUR build, and reads your finger from the sensor).
#
# Usage:
#   bash omarchy-setup-fingerprint.sh                 # full setup
#   bash omarchy-setup-fingerprint.sh --detect        # only identify the reader
#   bash omarchy-setup-fingerprint.sh --pam-only      # skip install/enroll, just wire PAM

set -euo pipefail

VALIDITY_IDS="138a:0090 138a:0097 138a:009d 06cb:009a"
GATE="auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
LOCK_FILE="/etc/pam.d/omarchy-lock-fingerprint"

_READER_LINE=""
_READER_ID=""
_READER_DESC=""
STACK=""

usage() {
  echo "Usage: bash $0 [--detect|--pam-only]"
  exit "${1:-0}"
}

info()  { echo -e "\e[32m[info]\e[0m $*"; }
warn()  { echo -e "\e[33m[warn]\e[0m $*" >&2; }
die()   { echo -e "\e[31m[error]\e[0m $*" >&2; exit 1; }

# --- 1. detect --------------------------------------------------------------
detect_reader() {
  local line
  line="$(lsusb | grep -iE 'fingerprint' | head -1 || true)"
  if [[ -z "$line" ]]; then
    # fallback: known fingerprint-reader vendor IDs (Synaptics/Validity)
    line="$(lsusb | grep -E '(06cb:|138a:)' | head -1 || true)"
  fi
  [[ -z "$line" ]] && return 1

  _READER_LINE="$line"
  _READER_ID="$(sed -nE 's/.*\bID ([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\b.*/\1/p' <<<"$line" | tr 'A-F' 'a-f')"
  _READER_DESC="$(sed -E 's/.*\bID [0-9a-fA-F]{4}:[0-9a-fA-F]{4} //' <<<"$line")"
  [[ -n "$_READER_ID" ]] || return 1
}

classify() {
  local id
  for id in $VALIDITY_IDS; do
    if [[ "$id" == "$_READER_ID" ]]; then
      STACK="validity"
      return 0
    fi
  done
  STACK="libfprint"
}

# --- 2. install -------------------------------------------------------------
stack_missing() {
  if [[ "$STACK" == "validity" ]]; then
    command -v fprintd-enroll >/dev/null 2>&1 && \
    [[ -f /usr/lib/systemd/system/python3-validity.service ]] && return 1
  else
    command -v fprintd-enroll >/dev/null 2>&1 && \
    [[ -f /usr/lib/systemd/system/fprintd.service ]] && return 1
  fi
  return 0
}

install_stack() {
  if [[ "$STACK" == "validity" ]]; then
    if command -v omarchy-pkg-aur-add >/dev/null 2>&1; then
      info "Installing python-validity stack via omarchy-pkg-aur-add (yay)..."
      omarchy-pkg-aur-add python-validity
    elif command -v yay >/dev/null 2>&1; then
      info "Installing python-validity stack via yay..."
      yay -S --noconfirm --needed python-validity open-fprintd fprintd-clients-git
    else
      die "no AUR helper found. Install python-validity open-fprintd fprintd-clients manually."
    fi
  else
    info "Installing fprintd + libfprint via pacman..."
    sudo pacman -S --noconfirm --needed fprintd libfprint
  fi
}

# --- 3. services ------------------------------------------------------------
enable_services() {
  if [[ "$STACK" == "validity" ]]; then
    info "Enabling open-fprintd + python3-validity services..."
    sudo systemctl enable --now open-fprintd.service python3-validity.service 2>/dev/null \
      || sudo systemctl start open-fprintd.service python3-validity.service
    if [[ -f /usr/lib/systemd/system/python3-validity-suspend-hotfix.service ]]; then
      sudo systemctl enable python3-validity-suspend-hotfix.service 2>/dev/null || true
    fi
  else
    info "Enabling fprintd service..."
    sudo systemctl enable --now fprintd.service 2>/dev/null \
      || sudo systemctl start fprintd.service
  fi
}

# --- 4. enroll + verify -----------------------------------------------------
enroll_finger() {
  local enrolled=0 ans
  enrolled="$(fprintd-list "$USER" 2>/dev/null | grep -c '^- #' || true)"
  if [[ "$enrolled" -gt 0 ]]; then
    read -r -p "A finger is already enrolled ($enrolled). Re-enroll/add anyway? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { info "Skipping enrollment."; return 0; }
  fi
  info "Enrolling. Keep touching/moving your finger on the sensor until it completes."
  sudo fprintd-enroll "$USER" || die "Enrollment failed. Run again to re-enroll."
  info "Verifying..."
  fprintd-verify || warn "Verification failed — try re-running this script."
}

# --- 5. PAM -----------------------------------------------------------------
wire_pam() {
  [[ -f /usr/lib/security/pam_fprintd.so ]] \
    || warn "pam_fprintd.so not found — PAM lines may not load until it is installed."

  # sudo
  if ! grep -q pam_fprintd.so /etc/pam.d/sudo 2>/dev/null; then
    sudo sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/sudo
  fi
  if [[ -x /usr/bin/omarchy-hw-laptop-closed ]] && ! grep -q omarchy-hw-laptop-closed /etc/pam.d/sudo 2>/dev/null; then
    sudo sed -i "/pam_fprintd\.so/i $GATE" /etc/pam.d/sudo
  fi

  # polkit
  if [[ -f /etc/pam.d/polkit-1 ]]; then
    if ! grep -q pam_fprintd.so /etc/pam.d/polkit-1 2>/dev/null; then
      sudo sed -i '1i auth      sufficient pam_fprintd.so' /etc/pam.d/polkit-1
    fi
    if [[ -x /usr/bin/omarchy-hw-laptop-closed ]] && ! grep -q omarchy-hw-laptop-closed /etc/pam.d/polkit-1 2>/dev/null; then
      sudo sed -i "/pam_fprintd\.so/i $GATE" /etc/pam.d/polkit-1
    fi
  else
    if [[ -x /usr/bin/omarchy-hw-laptop-closed ]]; then
      sudo tee /etc/pam.d/polkit-1 >/dev/null <<EOF
$GATE
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
    else
      sudo tee /etc/pam.d/polkit-1 >/dev/null <<'EOF'
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
    fi
  fi

  # Omarchy lock screen
  if [[ ! -f "$LOCK_FILE" ]]; then
    sudo tee "$LOCK_FILE" >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
EOF
  fi
}

# --- main -------------------------------------------------------------------
MODE="full"
case "${1:-}" in
  ""|--full) MODE="full" ;;
  --detect)  MODE="detect" ;;
  --pam-only) MODE="pam-only" ;;
  -h|--help) usage ;;
  *) die "unknown argument '$1'";;
esac

if ! command -v lsusb >/dev/null 2>&1; then
  die "lsusb not found (usbutils). Install it first."
fi

if ! detect_reader; then
  die "no fingerprint reader detected on the USB bus."
fi

echo "=== Fingerprint reader ==="
echo "  line : $_READER_LINE"
echo "  ID   : $_READER_ID"
echo "  model: $_READER_DESC"

classify
echo "  stack: $STACK ($( [[ "$STACK" == validity ]] && echo 'python-validity/open-fprintd' || echo 'fprintd/libfprint' ))"

if [[ "$MODE" == "detect" ]]; then
  echo
  echo "Detection only — nothing was installed or changed."
  echo "Run with no arguments (or --full) to perform the full setup."
  exit 0
fi

# full and pam-only both need root later; grab the sudo timestamp up front
sudo -v

if [[ "$MODE" == "full" ]]; then
  if stack_missing; then
    install_stack
  else
    info "Driver stack already installed."
  fi
  enable_services
  enroll_finger
fi

wire_pam

echo
info "Done! Fingerprint authentication is configured."
echo "  sudo and polkit prompts: fingerprint or password"
echo "  lock screen: fingerprint (omarchy-lock-fingerprint)"
echo
echo "Test with: sudo -k true   (or)   omarchy lock"
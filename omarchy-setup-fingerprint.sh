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
#   bash omarchy-setup-fingerprint.sh --enroll        # add/change fingerprints
#   bash omarchy-setup-fingerprint.sh --verify        # test a finger, wire PAM if it matches
#   bash omarchy-setup-fingerprint.sh --reset         # wipe the sensor chip + stored prints
#   bash omarchy-setup-fingerprint.sh --remove        # remove a specific finger or all
#   bash omarchy-setup-fingerprint.sh --list          # list enrolled fingerprints
#   bash omarchy-setup-fingerprint.sh --status        # show full configuration status
#   bash omarchy-setup-fingerprint.sh --disable       # disable fingerprint PAM (keep enrolled)
#   bash omarchy-setup-fingerprint.sh --enable        # re-enable fingerprint PAM
#   bash omarchy-setup-fingerprint.sh --uninstall     # remove packages, PAM, services
#   bash omarchy-setup-fingerprint.sh --pam-only      # skip install/enroll, just wire PAM
#
# Notes on the Validity/Synaptics stack (python-validity):
#   * It stores records on the sensor itself. Re-enrolling a finger that is
#     already stored fails with "Failed: 04c3" (duplicate record), so the
#     script deletes existing prints before enrolling them again.
#   * A chip whose records went stale (old enrollments, interrupted runs)
#     enrolls fine but never matches on verify. --reset runs the documented
#     factory-reset sequence to clear it; then enroll fresh.

set -euo pipefail

VALIDITY_IDS="138a:0090 138a:0097 138a:009d 06cb:009a"
GATE="auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"
LOCK_FILE="/etc/pam.d/omarchy-lock-fingerprint"

FINGER_NAMES=(left-thumb left-index-finger left-middle-finger left-ring-finger left-little-finger \
              right-thumb right-index-finger right-middle-finger right-ring-finger right-little-finger)

_READER_LINE=""
_READER_ID=""
_READER_DESC=""
STACK=""
VERIFY_OK=0

usage() {
  echo "Usage: bash $0 [--detect|--enroll|--verify|--reset|--remove|--list|--status|--disable|--enable|--uninstall|--pam-only]"
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
    # fprintd-clients-git ships fprintd-enroll/pam_fprintd and replaces the
    # stock fprintd package; both installed at once means a half-migrated
    # system where the daemon and the PAM module disagree.
    command -v fprintd-enroll >/dev/null 2>&1 &&
      [[ -f /usr/lib/systemd/system/open-fprintd.service ]] &&
      [[ -f /usr/lib/systemd/system/python3-validity.service ]] &&
      ! pacman -Q fprintd >/dev/null 2>&1 && return 1
  else
    command -v fprintd-enroll >/dev/null 2>&1 && \
    [[ -f /usr/lib/systemd/system/fprintd.service ]] && return 1
  fi
  return 0
}

remove_conflicting_stack() {
  local p
  # fprintd-clients-git conflicts with stock fprintd (same binaries and
  # pam_fprintd.so). With --noconfirm pacman answers the conflict prompt "N"
  # and aborts, leaving the install half-done.
  for p in fprintd libfprint-git; do
    if pacman -Q "$p" >/dev/null 2>&1; then
      info "Removing $p (the validity stack ships its own fprintd clients)..."
      sudo pacman -Rns --noconfirm "$p" || warn "could not remove $p — remove it manually"
    fi
  done
}

install_stack() {
  if [[ "$STACK" == "validity" ]]; then
    remove_conflicting_stack
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
    # Upload firmware first (needs device free), then start services
    if ! sensor_present_after_start; then
      upload_firmware
    fi
    sudo systemctl enable --now open-fprintd.service python3-validity.service 2>/dev/null \
      || sudo systemctl start open-fprintd.service python3-validity.service
    if [[ -f /usr/lib/systemd/system/python3-validity-suspend-hotfix.service ]]; then
      sudo systemctl enable python3-validity-suspend-hotfix.service 2>/dev/null || true
    fi
    for s in open-fprintd-suspend.service open-fprintd-resume.service; do
      [[ -f "/usr/lib/systemd/system/$s" ]] && sudo systemctl enable "$s" 2>/dev/null || true
    done
  else
    info "Enabling fprintd service..."
    sudo systemctl enable --now fprintd.service 2>/dev/null \
      || sudo systemctl start fprintd.service
  fi
}

sensor_present_after_start() {
  # Try starting temporarily to check sensor, then stop
  sudo systemctl start open-fprintd.service python3-validity.service 2>/dev/null || true
  sleep 2
  local present=0
  timeout 10 fprintd-list "$USER" 2>/dev/null | grep -q 'Device at' && present=1
  sudo systemctl stop open-fprintd.service python3-validity.service 2>/dev/null || true
  sleep 1
  return $present
}

sensor_present() {
  timeout 10 fprintd-list "$USER" 2>/dev/null | grep -q 'Device at'
}

upload_firmware() {
  command -v validity-sensors-firmware >/dev/null 2>&1 || return 1
  info "Sensor not detected — uploading firmware with validity-sensors-firmware..."
  sudo validity-sensors-firmware || return 1
  sleep 2
  sensor_present
}

# --- 4. enroll + verify -----------------------------------------------------
# A previous run (or a manual fprintd-verify left waiting for a finger) keeps
# the device claimed, and every later call fails with "Device is already in
# use". Drop the stale clients and restart the broker to clear the claim.
kill_clients() {
  pkill -x fprintd-enroll 2>/dev/null || true
  pkill -x fprintd-verify 2>/dev/null || true
  pkill -x fprintd-list 2>/dev/null || true
  pkill -x fprintd-delete 2>/dev/null || true
  sleep 1
}

release_device() {
  kill_clients
  if [[ "$STACK" == "validity" ]]; then
    sudo systemctl restart open-fprintd.service 2>/dev/null || true
    sleep 1
  fi
}

enrolled_list() {
  timeout 10 fprintd-list "$USER" 2>/dev/null | grep '^- #' | sed 's/.*: *//'
}

delete_all_prints() {
  info "Deleting all enrolled fingerprints for $USER..."
  timeout 15 fprintd-delete "$USER" 2>/dev/null \
    || warn "fprintd-delete failed — the sensor may still hold old records."
}

# python-validity keeps its records on the sensor. Enrolling a finger that is
# already there fails with "Failed: 04c3" (duplicate record), and stale
# records make verify return no-match forever, so start from a clean slate.
clear_for_enroll() {
  local -a already=("$@")
  [[ ${#already[@]} -eq 0 ]] && return 0

  if [[ "$STACK" == "validity" ]]; then
    warn "Already enrolled: ${already[*]}"
    info "This driver cannot overwrite a stored record, so all prints are cleared first."
    local ans
    read -r -p "Clear the existing fingerprints and re-enroll? [Y/n] " ans
    case "${ans,,}" in
      n|no) return 1 ;;
    esac
    release_device
    delete_all_prints
    release_device
  else
    local f
    for f in "${already[@]}"; do
      timeout 15 fprintd-delete -f "$f" "$USER" 2>/dev/null || true
    done
  fi
}

enroll_one() {
  local finger="$1"
  release_device
  info "Enrolling $finger. Keep touching/moving your finger until it completes."
  if ! sudo fprintd-enroll -f "$finger" "$USER"; then
    warn "Enrollment of $finger failed — run --enroll again to retry."
    return 1
  fi
  info "Verifying $finger (place the same finger on the sensor)..."
  if fprintd-verify -f "$finger" 2>&1 | grep -q 'verify-match'; then
    info "$finger verified."
    VERIFY_OK=1
  else
    warn "Verification of $finger failed — run --verify to try again."
    return 1
  fi
}

enroll_finger() {
  local -a enrolled=() sel=() clash=()
  local choice c i f ans

  mapfile -t enrolled < <(enrolled_list)
  echo
  if [[ ${#enrolled[@]} -gt 0 ]]; then
    info "Already enrolled: ${enrolled[*]}"
  else
    info "No fingerprints enrolled yet."
  fi

  echo
  echo "Select fingers to enroll (numbers may be combined, e.g. '1 3 5', or 'all'):"
  for i in "${!FINGER_NAMES[@]}"; do
    printf '  %2d) %s\n' "$((i+1))" "${FINGER_NAMES[$i]}"
  done
  echo
  read -r -p "=> " choice
  [[ -z "$choice" ]] && { info "Nothing to enroll."; return 0; }
  if [[ "$choice" == "all" || "$choice" == "*" ]]; then
    choice="$(seq 1 "${#FINGER_NAMES[@]}")"
  fi

  for c in $choice; do
    if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#FINGER_NAMES[@]} )); then
      sel+=("${FINGER_NAMES[c-1]}")
    else
      warn "ignoring invalid choice '$c'"
    fi
  done
  (( ${#sel[@]} )) || { warn "no valid fingers selected."; return 1; }

  for f in "${sel[@]}"; do
    [[ " ${enrolled[*]-} " == *" $f "* ]] && clash+=("$f")
  done
  if (( ${#clash[@]} )) && ! clear_for_enroll "${clash[@]}"; then
    info "Keeping the existing prints unchanged; skipping re-enroll."
    return 0
  fi

  info "Enrolling: ${sel[*]}"
  for f in "${sel[@]}"; do
    enroll_one "$f" || true
  done
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

# --- 6. reset + verify ---------------------------------------------------------------
# python-validity can leave the chip holding records from earlier runs (or
# from a different install). Those make verify return no-match forever and
# make a second enroll fail with "Failed: 04c3". This is the sequence from
# the upstream README: stop the driver, refresh the firmware, wipe the chip.
reset_sensor() {
  [[ "$STACK" == "validity" ]] \
    || die "--reset only applies to the validity (python-validity) stack."

  warn "This wipes every fingerprint stored on the sensor chip."
  local ans
  read -r -p "Factory-reset the sensor? [y/N] " ans
  case "${ans,,}" in
    y|yes) ;;
    *) info "Aborted."; return 0 ;;
  esac

  kill_clients
  info "Stopping the driver..."
  sudo systemctl stop python3-validity.service open-fprintd.service 2>/dev/null || true
  sleep 2

  # Wait for USB device to be fully released
  local i=0
  while fuser /dev/bus/usb/*/* 2>/dev/null | grep -q "python3-validity\|open-fprintd" && (( i < 10 )); do
    sleep 1
    ((i++))
  done

  if [[ -f /usr/share/python-validity/playground/factory-reset.py ]]; then
    info "Factory-resetting the sensor chip..."
    sudo python3 /usr/share/python-validity/playground/factory-reset.py \
      || warn "factory-reset reported an error"
  else
    warn "/usr/share/python-validity/playground/factory-reset.py not installed."
  fi

  if command -v validity-sensors-firmware >/dev/null 2>&1; then
    info "Refreshing sensor firmware (needs network)..."
    sudo validity-sensors-firmware || warn "validity-sensors-firmware failed — continuing"
  fi

  sudo systemctl start python3-validity.service open-fprintd.service
  sleep 3

  # Wait for sensor to appear
  local tries=0
  while ! timeout 5 fprintd-list "$USER" 2>/dev/null | grep -q 'Device at' && (( tries < 10 )); do
    sleep 1
    ((tries++))
  done

  timeout 15 fprintd-delete "$USER" 2>/dev/null || true
  info "Sensor wiped. Re-run the script to enroll a finger."
}

verify_finger() {
  local -a enrolled=()
  local f choice

  mapfile -t enrolled < <(enrolled_list)
  (( ${#enrolled[@]} )) || { warn "no fingerprints enrolled yet — run --enroll first."; return 1; }

  release_device
  if [[ ${#enrolled[@]} -eq 1 ]]; then
    f="${enrolled[0]}"
  else
    info "Enrolled: ${enrolled[*]}"
    read -r -p "Finger to test (name, or 'any'): " choice
    f="${choice:-any}"
  fi

  info "Verifying $f — place your finger on the sensor..."
  if [[ "$f" == "any" ]]; then
    fprintd-verify 2>&1 | grep -q 'verify-match' && VERIFY_OK=1
  else
    fprintd-verify -f "$f" 2>&1 | grep -q 'verify-match' && VERIFY_OK=1
  fi
}

# --- 6. remove ---------------------------------------------------------------
remove_finger() {
  local -a enrolled=()
  local f choice

  mapfile -t enrolled < <(enrolled_list)
  (( ${#enrolled[@]} )) || { warn "no fingerprints enrolled."; return 0; }

  echo "Enrolled: ${enrolled[*]}"
  read -r -p "Finger to remove (name, or 'all'): " choice
  f="${choice:-}"
  [[ -z "$f" ]] && { warn "nothing selected."; return 0; }

  release_device
  if [[ "$f" == "all" ]]; then
    info "Removing all enrolled fingerprints..."
    delete_all_prints
  else
    info "Removing $f..."
    timeout 15 fprintd-delete -f "$f" "$USER" 2>/dev/null \
      || warn "failed to remove $f (may not exist)."
  fi
  release_device
  info "Done. Current prints: $(timeout 10 fprintd-list "$USER" 2>/dev/null | grep -c '^- #' || true)"
}

# --- 7. list ---------------------------------------------------------------
list_prints() {
  local -a enrolled=()
  mapfile -t enrolled < <(enrolled_list)
  if (( ${#enrolled[@]} )); then
    info "Enrolled fingerprints for $USER:"
    for f in "${enrolled[@]}"; do
      echo "  - $f"
    done
  else
    info "No fingerprints enrolled."
  fi
}

# --- 8. status ---------------------------------------------------------------
show_status() {
  echo "=== Fingerprint Configuration Status ==="
  echo
  echo "Reader: $_READER_DESC ($_READER_ID)"
  echo "Stack:  $STACK"
  echo
  echo "--- Packages ---"
  if [[ "$STACK" == "validity" ]]; then
    for p in python-validity open-fprintd fprintd-clients-git; do
      pacman -Q "$p" >/dev/null 2>&1 && echo "  [installed] $p" || echo "  [missing] $p"
    done
    pacman -Q fprintd >/dev/null 2>&1 && echo "  [CONFLICT] fprintd (stock) installed — should be removed"
  else
    for p in fprintd libfprint; do
      pacman -Q "$p" >/dev/null 2>&1 && echo "  [installed] $p" || echo "  [missing] $p"
    done
  fi
  echo
  echo "--- Services ---"
  if [[ "$STACK" == "validity" ]]; then
    for s in open-fprintd python3-validity python3-validity-suspend-hotfix open-fprintd-suspend open-fprintd-resume; do
      systemctl is-active --quiet "$s" 2>/dev/null && echo "  [active] $s" || systemctl is-enabled --quiet "$s" 2>/dev/null && echo "  [enabled] $s" || echo "  [inactive] $s"
    done
  else
    systemctl is-active --quiet fprintd 2>/dev/null && echo "  [active] fprintd" || echo "  [inactive] fprintd"
  fi
  echo
  echo "--- PAM ---"
  for f in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
    [[ -f "$f" ]] && grep -q pam_fprintd.so "$f" 2>/dev/null && echo "  [wired] $f" || echo "  [not wired] $f"
  done
  [[ -f "$LOCK_FILE" ]] && echo "  [wired] $LOCK_FILE" || echo "  [not wired] $LOCK_FILE"
  echo
  echo "--- Enrolled fingerprints ---"
  list_prints
}

# --- 9. disable / enable PAM -------------------------------------------------
toggle_pam() {
  local action="$1"  # disable or enable
  local pam_files=("/etc/pam.d/sudo" "/etc/pam.d/polkit-1")

  if [[ "$action" == "disable" ]]; then
    info "Disabling fingerprint PAM (keeping enrolled prints)..."
    for f in "${pam_files[@]}"; do
      [[ -f "$f" ]] && sudo sed -i '/pam_fprintd\.so/d; /omarchy-hw-laptop-closed/d' "$f" && echo "  $f: removed pam_fprintd lines"
    done
    if [[ -f "$LOCK_FILE" ]]; then
      sudo mv "$LOCK_FILE" "${LOCK_FILE}.disabled" 2>/dev/null && echo "  $LOCK_FILE: renamed to .disabled"
    fi
    info "Fingerprint authentication disabled. Password-only fallback active."
  else
    info "Re-enabling fingerprint PAM..."
    wire_pam
    info "Fingerprint authentication re-enabled."
  fi
}

# --- 10. uninstall -----------------------------------------------------------
uninstall_stack() {
  warn "This will remove ALL fingerprint packages, services, and PAM configuration."
  local ans
  read -r -p "Continue? [y/N] " ans
  case "${ans,,}" in
    y|yes) ;;
    *) info "Aborted."; return 0 ;;
  esac

  info "Stopping and disabling services..."
  if [[ "$STACK" == "validity" ]]; then
    sudo systemctl disable --now open-fprintd python3-validity python3-validity-suspend-hotfix open-fprintd-suspend open-fprintd-resume 2>/dev/null || true
    sudo pacman -Rns --noconfirm python-validity open-fprintd fprintd-clients-git 2>/dev/null || true
    # also remove stock fprintd if it somehow got installed
    sudo pacman -Rns --noconfirm fprintd libfprint 2>/dev/null || true
  else
    sudo systemctl disable --now fprintd 2>/dev/null || true
    sudo pacman -Rns --noconfirm fprintd libfprint 2>/dev/null || true
  fi

  info "Removing PAM configuration..."
  for f in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
    [[ -f "$f" ]] && sudo sed -i '/pam_fprintd\.so/d; /omarchy-hw-laptop-closed/d' "$f" && echo "  cleaned $f"
  done
  [[ -f "$LOCK_FILE" ]] && sudo rm -f "$LOCK_FILE" && echo "  removed $LOCK_FILE"
  [[ -f "${LOCK_FILE}.disabled" ]] && sudo rm -f "${LOCK_FILE}.disabled"

  info "Fingerprint stack completely removed."
}

# --- main -------------------------------------------------------------------
MODE="full"
case "${1:-}" in
  ""|--full) MODE="full" ;;
  --detect)  MODE="detect" ;;
  --enroll)  MODE="enroll" ;;
  --verify)  MODE="verify" ;;
  --reset)   MODE="reset" ;;
  --remove)  MODE="remove" ;;
  --list)    MODE="list" ;;
  --status)  MODE="status" ;;
  --disable) MODE="disable" ;;
  --enable)  MODE="enable" ;;
  --uninstall) MODE="uninstall" ;;
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

if [[ "$MODE" == "list" ]]; then
  list_prints
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  show_status
  exit 0
fi

# everything below edits system state or talks to the reader
sudo -v

if [[ "$MODE" == "reset" ]]; then
  reset_sensor
  exit 0
fi

if [[ "$MODE" == "remove" ]]; then
  if stack_missing; then
    die "driver stack not installed yet."
  fi
  remove_finger
  exit 0
fi

if [[ "$MODE" == "disable" || "$MODE" == "enable" ]]; then
  toggle_pam "$MODE"
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  uninstall_stack
  exit 0
fi

if [[ "$MODE" == "enroll" || "$MODE" == "verify" ]] && stack_missing; then
  die "driver stack not installed yet — run the full setup first."
fi

if [[ "$MODE" == "full" ]]; then
  if stack_missing; then
    install_stack
  else
    info "Driver stack already installed."
  fi
  enable_services
  enroll_finger
fi

if [[ "$MODE" == "enroll" ]]; then
  enroll_finger
  echo
  info "Current prints: $(timeout 10 fprintd-list "$USER" 2>/dev/null | grep -c '^- #' || true)"
  echo
fi

if [[ "$MODE" == "verify" ]]; then
  verify_finger || warn "verification failed."
  echo
fi

if [[ "$MODE" == "pam-only" ]] || (( VERIFY_OK )); then
  wire_pam

  echo
  info "Done! Fingerprint authentication is configured."
  echo "  sudo and polkit prompts: fingerprint or password"
  echo "  lock screen: fingerprint (omarchy-lock-fingerprint)"
  echo
  echo "Test with: sudo -k true   (or)   omarchy lock"
else
  echo
  warn "No finger verified, so PAM was left untouched — sudo/polkit/lock still ask for the password."
  echo "  Fix it with:  bash $0 --verify     (test an enrolled finger)"
  echo "                bash $0 --enroll     (add a finger)"
  echo "                bash $0 --reset      (wipe a stale sensor, then enroll)"
  exit 1
fi
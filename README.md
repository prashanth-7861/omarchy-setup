# Omarchy System Setup — Default Editor (nano) & Fingerprint Authentication

Practical setup notes for a ThinkPad T480 running **Omarchy** (Arch-based).

- Host: `pm`
- User: `omarchy`
- Kernel: `7.2.5-3-omarchy`

---

## 1. Hardware scan

```
$ lsusb
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
Bus 001 Device 002: ID 8087:0a2b Intel Corp. Bluetooth wireless interface
Bus 001 Device 003: ID 13d3:56a6 IMC Networks Integrated Camera
Bus 001 Device 005: ID 06cb:009a Synaptics, Inc. Metallica MIS Touch Fingerprint Reader
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 002 Device 002: ID 0bda:0316 Realtek Semiconductor Corp. Card Reader
Bus 003 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
Bus 004 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
```

**Fingerprint reader identified:** `06cb:009a` — Synaptics "Metallica MIS Touch". Vendor `06cb` (Synaptics) / product `009a` puts it in the **Validity** family, which the stock `libfprint` cannot drive. It requires the **python-validity** stack (Open-Fprintd).

---

## 2. Part A — `nano` as the default editor (replacing vim/neovim)

**Before:** `EDITOR="omarchy-launch-editor --inline"`, defaulting to **neovim** on launch.

**After:** every editor entry point opens **nano**.

### What was changed (all user-level — survives `omarchy update`)

| # | Location | Change |
|---|----------|--------|
| 1 | `~/.local/state/omarchy/defaults/editor` | contents = `nano` (the state file `omarchy default editor` writes/reads; `omarchy-launch-editor` dispatches `nano` via its built-in TUI path) |
| 2 | `~/.bashrc`, `~/.bash_profile` | `export EDITOR=nano`, `export VISUAL=nano`, `export SUDO_EDITOR=nano` |
| 3 | `~/.profile` | same exports (sh login shells) |
| 4 | git | `git config --global core.editor nano` |
| 5 | `~/.config/fish/conf.d/editor.fish` | `set -x EDITOR nano`, `set -x VISUAL nano`, `set -x SUDO_EDITOR nano` |

Omarchy's `default/bash/envs` only sets `EDITOR` via `export EDITOR="${EDITOR:-omarchy-launch-editor --inline}"`, so a user-level export always wins. `SUDO_EDITOR` follows so `visudo`/`sudoedit` also open nano.

> **Note:** the upstream `omarchy default editor` picker (code/cursor/zed/sublime_text/helix/vim/emacs/nvim) does not list `nano` yet, but `omarchy-launch-editor` already supports it at launch time — hence setting the state file directly achieves the result.

### Verify

```bash
bash -lc 'echo "$EDITOR" "$VISUAL" "$SUDO_EDITOR"'   # nano nano nano
omarchy default editor                                # nano
git config --global core.editor                       # nano
```

---

## 3. Part B — Fingerprint authentication

### 3.1 Detect the scanner (any device)

```bash
lsusb | grep -i fingerprint
```

Identify the `vendor:product` USB ID. Look it up to pick the right driver stack:

| USB ID | Reader | Driver stack |
|--------|--------|--------------|
| `138a:0090`, `138a:0097`, `138a:009d`, `06cb:009a` | Validity / Synaptics (incl. this T480) | **python-validity** + **open-fprintd** |
| most others (Goodix, Elan, AuthenTec, UPEK, …) | libfprint-supported | **fprintd** + **libfprint** |

### 3.2 Install required packages

Arch/Omarchy (AUR for the Validity stack):

```bash
omarchy-pkg-aur-add python-validity   # pulls open-fprintd + fprintd-clients
```

Installed set on this machine:

```
python-validity 0.15-1
open-fprintd 0.7-2
fprintd-clients-git 1.90.1.r2.g54e56d6-10
libfprint 1.94.100-1
```

`open-fprintd` owns the `net.reactivated.Fprint` D-Bus name (it replaces plain `fprintd`). `python-validity` is the low-level driver talking to the sensor via `/usr/lib/python-validity/dbus-service`.

For a standard libfprint reader instead:

```bash
sudo pacman -S fprintd libfprint
```

### 3.3 Enable services

```bash
sudo systemctl enable --now open-fprintd.service python3-validity.service
sudo systemctl enable python3-validity-suspend-hotfix.service   # lid/suspend firmware fix
systemctl is-active open-fprintd python3-validity               # active  active
```

### 3.4 Enroll a finger

```bash
fprintd-enroll -f right-index-finger
```

Follow the on-screen prompt, lifting/re-applying the finger on the sensor.

### 3.5 Verify

```bash
fprintd-verify           # place finger — Verified
fprintd-list "$USER"
```

Result on this machine:

```
Fingerprints for user omarchy on DBus driver (press):
 - #0: right-index-finger
```

### 3.6 Wire PAM authentication

`pam_fprintd.so` ships with `fprintd-clients` at `/usr/lib/security/pam_fprintd.so`.

**`/etc/pam.d/sudo`** — prepend:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
```

**`/etc/pam.d/polkit-1`** — prepend the same two lines above `auth required pam_unix.so`:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      required pam_unix.so
```

**`/etc/pam.d/omarchy-lock-fingerprint`** (lockscreen / lock command) — whole file:

```
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
```

> The `omarchy-hw-laptop-closed` gate refuses fingerprint auth while the laptop lid is closed — the T480’s validity sensor doesn’t work with the lid shut.

### 3.7 Test

- `sudo -A` / run any `sudo` command → should offer fingerprint.
- Lock the screen (`omarchy lock`) → unlock with a finger.
- GUI auth prompts (polkit) → fingerprint accepted.

---

## 4. Omarchy native path (upstream)

`omarchy setup security fingerprint` from the basecamp/omarchy fix (PR: omacom/omarchy#13187) now auto-detects Validity/Synaptics readers via `omarchy hw fingerprint validity` and installs the python-validity stack automatically.

- New detector: `bin/omarchy-hw-fingerprint-validity` (IDs `138a:0090`, `138a:0097`, `138a:009d`, `06cb:009a`)
- Detectors register with `omarchy --check` and power `omarchy setup security fingerprint`
- Removal: `omarchy remove security fingerprint`

On a **production** install the stack is set up manually (as above) to avoid a D-Bus name conflict with a stock `fprintd` install; the local helper script `~/setup-t480-fingerprint.sh` re-runs enroll + PAM wiring in one shot.

### Troubleshooting / removal

```bash
# remove the whole stack
sudo systemctl disable --now python3-validity.service open-fprintd.service
sudo systemctl disable python3-validity-suspend-hotfix.service
omarchy-pkg-aur-remove python-validity open-fprintd fprintd-clients
# restore the PAM files (drop the prepended lines)
```

---

## Quick reference

| Task | Command |
|------|---------|
| Detect reader | `lsusb \| grep -i fingerprint` |
| Install validity stack | `omarchy-pkg-aur-add python-validity` |
| Enable daemons | `sudo systemctl enable --now open-fprintd python3-validity` |
| Enroll | `fprintd-enroll -f right-index-finger` |
| Verify | `fprintd-verify && fprintd-list "$USER"` |
| Default editor | `omarchy default editor` → state file `~/.local/state/omarchy/defaults/editor` → `nano` |
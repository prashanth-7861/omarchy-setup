# Omarchy System Setup — nano default editor, fingerprint auth & Windows VM repair

Three idempotent bash scripts automate common machine setup on **Omarchy** (Arch-based):

1. `omarchy-set-nano-editor.sh` — make **nano** the default text editor (instead of vim/neovim).
2. `omarchy-setup-fingerprint.sh` — detect the fingerprint reader on **any** device, install the
   matching driver stack, enroll + verify a finger, and wire PAM for sudo/polkit/lock screen.
3. `omarchy-fix-windows-vm.sh` — repair the `windows-vm` mount gates after the guest (or Samba)
   set a setgid bit on the shared folder, which makes `omarchy-windows-vm launch` refuse to start
   the VM; then launches it.

Tested on a ThinkPad T480 running Omarchy (kernel `7.2.5-3-omarchy`).

---

## Quick start

```bash
git clone https://github.com/prashanth-7861/omarchy-setup
cd omarchy-setup

bash omarchy-set-nano-editor.sh           # 1. nano becomes the default text editor
bash omarchy-setup-fingerprint.sh         # 2. full fingerprint setup (any reader)
bash omarchy-fix-windows-vm.sh --install   # 3. one-time permanent fix for the Windows VM
bash omarchy-fix-windows-vm.sh             #    (or use --check / plain launch)
```

| Script | Flags |
|--------|-------|
| `omarchy-set-nano-editor.sh` | *(none)* set nano everywhere · `--revert` restore the previous editor |
| `omarchy-setup-fingerprint.sh` | *(none/`--full`)* full setup · `--detect` identify the reader only · `--enroll` add/change fingerprints only · `--pam-only` wire PAM, skip install/enroll |
| `omarchy-fix-windows-vm.sh` | *(none)* clear bits, verify mount gates, then launch · `--check` only clear + verify, do not launch · `--install` patch the system script to tolerate the bits permanently (re-run after `omarchy update`) |

Run fingerprint setup from a real terminal — it prompts for the sudo password, may build AUR
packages (`yay`), and reads your finger from the sensor.

---

## 1. `omarchy-set-nano-editor.sh` — nano as the default editor

Omarchy ships `EDITOR="omarchy-launch-editor --inline"`, defaulting to **neovim**. The script
replaces it everywhere:

| # | Location | Change |
|---|----------|--------|
| 1 | `~/.local/state/omarchy/defaults/editor` | contents = `nano` (the state file `omarchy default editor` writes/reads; `omarchy-launch-editor` dispatches `nano` via its built-in TUI path) |
| 2 | `~/.bashrc`, `~/.bash_profile`, `~/.profile` | `export EDITOR=nano VISUAL=nano SUDO_EDITOR=nano`, inside an idempotent marker block |
| 3 | `git --global` | `core.editor nano` |
| 4 | `~/.config/fish/conf.d/editor.fish` | `set -x EDITOR/VISUAL/SUDO_EDITOR nano` |

All changes are user-level and survive `omarchy update`. Omarchy's `default/bash/envs` only sets
`EDITOR` via `export EDITOR="${EDITOR:-…}"`, so the user export always wins; `SUDO_EDITOR` follows
so `visudo`/`sudoedit` also open nano.

> **Note:** the upstream `omarchy default editor` picker (code/cursor/zed/sublime_text/helix/vim/emacs/nvim)
> does not list `nano` yet, but `omarchy-launch-editor` already supports it at launch time — hence
> setting the state file directly achieves the result.

### Verify

```bash
bash -lc 'echo "$EDITOR" "$VISUAL" "$SUDO_EDITOR"'   # nano nano nano
omarchy default editor                                # nano
git config --global core.editor                       # nano
```

---

## 2. `omarchy-setup-fingerprint.sh` — fingerprint authentication (any device)

### Detect the scanner

```bash
lsusb | grep -i fingerprint
```

Identify the `vendor:product` USB ID and pick the matching driver stack (the script does this
automatically, with a fallback scan of known fingerprint-vendor IDs):

| USB ID | Reader | Driver stack | Installed by |
|--------|--------|--------------|--------------|
| `138a:0090`, `138a:0097`, `138a:009d`, `06cb:009a` | Validity / Synaptics | `python-validity` + `open-fprintd` | AUR (`yay` / `omarchy-pkg-aur-add`) |
| most others (Goodix, Elan, AuthenTec, UPEK, …) | libfprint-supported | `fprintd` + `libfprint` | pacman |

On the reference T480 the reader is `06cb:009a` — Synaptics "Metallica MIS Touch". Vendor `06cb`
(Synaptics) / product `009a` puts it in the **Validity** family, which stock `libfprint` cannot
drive.

### What the script does

1. **Install** the stack (`python-validity` + deps via AUR, or `fprintd libfprint` via pacman).
2. **Enable services** — `open-fprintd.service` + `python3-validity.service` (+
   `python3-validity-suspend-hotfix.service` for the lid/suspend firmware fix), or `fprintd.service`.
   `open-fprintd` owns the `net.reactivated.Fprint` D-Bus name (it replaces plain `fprintd`).
3. **Enroll + verify** — interactive menu of the 10 standard finger names; pick one or more
   (e.g. `2 5`, or `all`) to enroll, each verified by `fprintd-verify -f`. Re-running with
   `--enroll` adds or replaces prints without touching the installed stack or PAM.
4. **Wire PAM** for `sudo`, `polkit-1`, and the Omarchy lock screen (`omarchy-lock-fingerprint`).

### PAM wiring (what gets written)

**`/etc/pam.d/sudo`** — prepend:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
```

**`/etc/pam.d/polkit-1`** — prepend the same two lines above `auth required pam_unix.so`.

**`/etc/pam.d/omarchy-lock-fingerprint`** (lock screen) — whole file:

```
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
```

> The `omarchy-hw-laptop-closed` gate (only added when that executable exists) refuses fingerprint
> auth while the laptop lid is closed — the T480’s validity sensor doesn’t work with the lid shut.

### Test

- Run any `sudo` command → fingerprint or password.
- Lock the screen (`omarchy lock`) → unlock with a finger.
- GUI auth prompts (polkit) → fingerprint accepted.

---

## 3. `omarchy-fix-windows-vm.sh` — repair & relaunch the Windows VM

### Symptom

`omarchy-windows-vm launch` fails right after a previous session:

```
❌ Failed to start Windows VM!
```

`omarchy-windows-vm stop` still works, but starting fails **instantly** and the Docker daemon
logs show nothing — the failure happens before Docker is ever contacted.

### Root cause

`omarchy-windows-vm`'s `assert_mounts_safe` → `mounted_leaf_matches()` requires every VM mount
leaf to have a mode **exactly `700`** (`bin/omarchy-windows-vm`):

```bash
[[ $actual == "$identity" && $owner == "$CALLER_UID" && $mode == 700 ]]
```

For a bind mount, the leaf at `/var/lib/omarchy/windows/mounts/users/1000/shared` mirrors the
source folder `~/Windows`. If the Windows guest (or Samba's shared-folder handling) sets the
**setgid bit** on `~/Windows`, the leaf reads `2700`, the check fails, and every `up` is refused
up-front — which is exactly the observed symptom (no container, no network, nothing in dockerd).

### What the script does

1. **Clears the special bits** (`chmod g-s` then `0700`) on `~/.windows` and `~/Windows` — the
   bind-mounted leaves mirror the fix automatically.
2. **Verifies the same gate the launcher uses**, for both `storage` and `shared` leaves:
   - anchor resolves & is a real single-layer bind mount,
   - leaf device:inode == source (`mounted_leaf_matches`),
   - leaf owner == caller uid, leaf mode == `700`.
   Missing or unmounted anchors are **SKIP**ped, not failed — the launcher re-creates and binds
   them itself.
3. If the gates are clean it **launches** `omarchy-windows-vm launch`; add `--check` to only
   clear + verify without launching (exit 0 on success, non-zero on a real failure).

Run it from a real terminal — the launch step prompts for root via polkit / fingerprint.

> **Recurring? Run `--install`.** The Windows guest re-applies the setgid bit after every run, so
> the plain clear+launch fix has to be repeated after each session. `--install` instead patches
> the installed script `/usr/bin/omarchy-windows-vm` (backup `…/omarchy-windows-vm.omarchyfix.bak`)
> to **mask the special bits** in both mount gates:
> `mode == 700` → `${mode: -3} == 700` (and the same for the `prepare_caller_mounts` mode check).
> The owner-only `0700` access check stays intact while setgid/setuid/sticky can no longer block a
> start, so plain `omarchy-windows-vm launch` works every time — until `omarchy update` reinstalls
> the packaged script, then run `--install` again.

### Verify

```bash
bash omarchy-fix-windows-vm.sh --check   # prints: PASS [storage] PASS [shared]
stat -c '%a' ~/Windows                   # 700 (was 2700 with the bug)
```

### Upstream note

The strict `mode == 700` test is a one-line hardening change upstream: masking the special bits
(`${mode: -3} == 700`) makes `mounted_leaf_matches` tolerate setgid/setuid sticky bits on the
host-side shared folder while keeping the access check intact.

---

## Reference machine state

Full USB scan (T480):

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

Installed fingerprint stack:

```
python-validity 0.15-1
open-fprintd 0.7-2
fprintd-clients-git 1.90.1.r2.g54e56d6-10
libfprint 1.94.100-1
```

Result:

```
Fingerprints for user omarchy on DBus driver (press):
 - #0: right-index-finger
```

---

## Upstream (Omarchy core)

`omarchy setup security fingerprint` from the basecamp/omarchy fix (PR:
[omacom/omarchy#13187](https://github.com/omacom/omarchy/pull/13187)) now auto-detects
Validity/Synaptics readers via `omarchy hw fingerprint validity` and installs the python-validity
stack automatically.

- New detector: `bin/omarchy-hw-fingerprint-validity` (IDs `138a:0090`, `138a:0097`, `138a:009d`, `06cb:009a`)
- Detectors register with `omarchy --check` and power `omarchy setup security fingerprint`
- Removal: `omarchy remove security fingerprint`

On a **production** install the stack is set up with `omarchy-setup-fingerprint.sh` instead, to
avoid a D-Bus name conflict with a stock `fprintd` install.

### Troubleshooting / removal

```bash
# remove the whole stack
sudo systemctl disable --now python3-validity.service open-fprintd.service
sudo systemctl disable python3-validity-suspend-hotfix.service   # validity only
omarchy-pkg-aur-remove python-validity open-fprintd fprintd-clients
# restore the PAM files (drop the prepended lines)
```

---

## Quick reference

| Task | Command |
|------|---------|
| Detect reader | `lsusb \| grep -i fingerprint` |
| nano as default editor | `bash omarchy-set-nano-editor.sh` |
| Full fingerprint setup | `bash omarchy-setup-fingerprint.sh` |
| Enroll more fingerprints | `bash omarchy-setup-fingerprint.sh --enroll` |
| Identify reader only | `bash omarchy-setup-fingerprint.sh --detect` |
| Wire PAM only | `bash omarchy-setup-fingerprint.sh --pam-only` |
| Revert nano default | `bash omarchy-set-nano-editor.sh --revert` |
| Windows VM won't start | `bash omarchy-fix-windows-vm.sh` |
| Check Windows VM mount gates | `bash omarchy-fix-windows-vm.sh --check` |
| Make the fix permanent | `bash omarchy-fix-windows-vm.sh --install` |
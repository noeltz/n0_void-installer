# Void Linux Installer — Development Specification

**Version:** 1.4 (draft for implementation; incorporates review findings and live-ISO realities: the ISO ships no curl/dialog and an outdated xbps; host tools come from the ISO's own base-system, no live-system packages are installed — mixing repo packages onto the old ISO userland breaks them, and a full sync does not fit in the ISO's RAM-backed root)
**Audience:** Senior developer implementing the installer. Nothing in this document is optional or open to interpretation unless it is explicitly marked *configurable*.
**Language of the deliverable:** Bash.

---

## 0. How to read this document

- **MUST / MUST NOT** are binary requirements. **MAY** marks an explicitly allowed variation.
- Every command shown is the exact command to run (variables in `$UPPER_CASE` are defined in section 6 or section 9).
- Package and service names were researched against the Void repositories. Because names can change, the installer MUST validate every package name **and every fatal service directory** against the mirror **before** touching any disk (section 10.1). A renamed package or a missing service therefore fails safely, before any destructive action. (Optional hardware services are checked after install and only warn.)
- Section 16 lists decisions the author made beyond the customer's answers. They are fixed for v1, but are collected in one place so they can be changed deliberately.

---

## 1. Goal and scope

Build a **single Bash script** that, when run from the **official Void Linux live ISO (glibc, x86_64) with a working network connection**, installs a complete, bootable Void Linux system onto one whole disk with:

- GPT, UEFI boot, GRUB
- btrfs with a fixed subvolume layout
- snapper snapshots created automatically around every `xbps-install` / `xbps-remove` transaction (last 10 kept)
- bootable snapshot menu in GRUB (grub-btrfs)
- NetworkManager networking
- hardware detection with matching drivers/firmware/services
- everything required to apply chezmoi-managed dotfiles from a remote GitHub repository, including their bootstrap scripts

The result is a **base system plus one user account**. No desktop environment, compositor or login manager is installed by the installer (the dotfiles do that).

### 1.1 Explicit non-goals (v1)

- musl, any architecture other than x86_64
- BIOS/legacy boot
- LUKS / any encryption
- Manual or dual-boot partitioning (the target disk is always wiped completely)
- Limine or any bootloader other than GRUB
- Dry-run mode, log files
- Proprietary NVIDIA driver
- Private dotfiles repositories (needs credentials)
- Booting snapshots with a writable overlay (read-only snapshot boot only, see 12.3)
- Snapshots of `/home`

---

## 2. Fixed decisions (summary table)

| Topic | Decision |
|---|---|
| Form | One Bash script `install.sh` + one example config `install.conf.example` |
| libc / arch | glibc / x86_64 only |
| Install source | Official Void live ISO, network required, packages from mirror |
| Live tools | None installed: the ISO's base-system provides all host tools (sfdisk partitions, not sgdisk); `dialog` installed on demand in interactive mode |
| Firmware | UEFI only. Abort if `/sys/firmware/efi` does not exist |
| Partitioning | Automatic, whole disk, GPT: 1 × ESP (1 GiB), 1 × btrfs (rest) |
| Filesystem | btrfs, subvolumes `@ @home @snapshots @var_log @var_cache_xbps @var_tmp` |
| Encryption | None |
| Swap | zram via `zramen` (default), or none (`SWAP=none`). No swap partition/file |
| Bootloader | GRUB (`grub-x86_64-efi`) + `grub-btrfs` + `grub-btrfs-runit` |
| Kernel | `linux` (current), initramfs by dracut (Void default) |
| Init / services | runit, services enabled by symlink |
| Network | NetworkManager only. `dhcpcd` and `wpa_supplicant` services MUST NOT be enabled |
| Snapshots | snapper config `root` for `/`, created around each xbps transaction by wrapper scripts, last 10 pairs kept |
| Dotfiles | chezmoi `init --apply` from a GitHub repo, run as the new user inside the chroot |
| UI | `dialog` for disk selection and value prompts; plain single-key `y` for final confirmation |
| Logging / dry-run | None |
| Tests | QEMU/KVM with OVMF first, then a physical laptop |

---

## 3. Deliverables and repository layout

```
void-installer/
├── install.sh              # the installer (single file, all helper scripts embedded as heredocs)
├── install.conf.example    # documented example configuration (section 6)
└── README.md               # short usage description: download, verify SHA-256 checksum (published next to the script), run
```

The installer MUST be a single file so it can be fetched on the live ISO with one `curl` command. The wrapper scripts for xbps (section 12) and any config files written to the target are embedded in `install.sh` as quoted heredocs (`<<'EOF'`).

### 3.1 Script conventions

- Shebang `#!/bin/bash`, first executable lines: `set -Eeuo pipefail`.
- All logic in functions; the last line of the file is `main "$@"`.
- Function names (fixed, so the call graph is predictable): `main`, `parse_args`, `load_config`, `preflight`, `detect_hardware`, `build_package_lists`, `probe_packages`, `choose_disk`, `prompt_missing`, `validate_all`, `confirm`, `partition_disk`, `format_disk`, `mount_layout`, `bootstrap_system`, `configure_system`, `setup_snapper`, `setup_grub`, `enable_services`, `create_user`, `apply_chezmoi`, `install_wrappers`, `initial_snapshot`, `finalize`, `cleanup`.
- Progress output: one line per step, format `==> [N/16] <step name>`. Before the first step line the script prints one banner `void-installer <INSTALLER_VERSION>` so a stale script is immediately detectable. Command output of tools is not suppressed. There is **no log file**.
- Quote every variable expansion. Use `[[ ]]` for tests. ShellCheck MUST pass with no warnings (disable directives only with a comment explaining why). The embedded heredocs (wrapper, config snippets) are invisible to ShellCheck: CI MUST extract script-type heredocs to temporary files and run ShellCheck on them separately.
- **ERR-trap discipline (binding).** Under `set -Eeuo pipefail`, expected failures would trigger the ERR trap and be reported as exit 1. Every command whose failure is an expected path MUST be guarded and mapped to its specified exit code:
  ```bash
  if ! choice=$(dialog ... 3>&1 1>&2 2>&3); then exit 4; fi   # Cancel (rc 1) and ESC (rc 255) both mean "user aborted"
  read -r -n1 -s answer || answer=""                         # EOF counts as "not y"
  rc=0; xbps-install ... || rc=$?                            # then map rc explicitly (e.g. exit 3 for the probe)
  ```
  SIGINT (Ctrl-C) ends with 130, which lies outside the exit-code table and is accepted.
- Do **not** set a global `umask 077` (it would make `/etc/hostname`, `/etc/fstab` etc. unreadable for normal users). Files holding secrets are not created by the installer at all (see 10.11).

---

## 4. Execution environment and live-ISO prerequisites

The installer runs as **root** on the Void live ISO. The official ISO ships **neither `curl` nor an xbps new enough for the current repositories** (both verified empirically), so the installer MUST NOT depend on either being present beforehand: check 6 tests the network using only bash's `/dev/tcp`, and the live-tools step (below) updates xbps first and installs `curl` together with the other tools. Preflight checks (function `preflight`, executed first, in this order; each failure prints one error line and exits with code 3, except check 0):

| # | Check | Command / condition | Error message |
|---|---|---|---|
| 0 | `MIRROR` syntax (only the syntax, runs before any network use) | `[[ $MIRROR =~ ^https://[^/]+(/[^/]+)*$ ]]` (no trailing slash, no `/current`) | `Invalid MIRROR (needs https://host[/path], no trailing slash, no /current).` (exit 2) |
| 1 | Running as root | `[[ $EUID -eq 0 ]]` | `Must be run as root.` |
| 2 | Bash ≥ 4.4 | `(( BASH_VERSINFO[0] > 4 \|\| (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))` | `Bash 4.4 or newer required.` |
| 3 | x86_64 | `[[ $(uname -m) == x86_64 ]]` | `Only x86_64 is supported.` |
| 4 | glibc live system | `ldd --version 2>&1 \| grep -qi 'GNU libc'` | `musl is not supported.` |
| 5 | UEFI boot | `[[ -d /sys/firmware/efi ]]` | `Not booted in UEFI mode.` |
| 6 | Network reachable (bash only, no external tools) | `timeout 10 bash -c "exec 3<>/dev/tcp/$HOST/443" 2>/dev/null` where `$HOST` is `$MIRROR` without `https://` and without any path | `No network connection to $MIRROR. Connect first and re-run.` |
| 7 | RAM ≥ 1 GiB | `MemTotal` in `/proc/meminfo` ≥ 1048576 kB | `At least 1 GiB RAM required.` |

After the checks, prepare the live environment. **No full live-system sync and no live-tools install**: a full sync needs more space (~2.5 GiB) than the ISO's RAM-backed root offers, and installing current repo packages onto the old ISO userland breaks binaries with `symbol lookup error` (both observed). Instead:

```bash
xbps-install -Syu xbps          # xbps self-update: an outdated xbps refuses all other transactions,
                                # including the target bootstrap later
xbps-query -R --repository="$MIRROR/current" base-system   # canary: the repository must be readable
```

The Void repositories moved to a **flat layout** in October 2026 (`/current/x86_64-repodata` instead of `/current/x86_64/x86_64-repodata`); an xbps from before that change cannot read the new layout and every package fails with "not found in repository pool". The canary query makes such a mismatch fail in preflight, before anything else runs.

If the self-update fails → `Failed to update xbps. If the mirror changed layout recently, this ISO's xbps may be too old to read it; use a newer ISO.` exit 3. If the canary fails → `Repository $MIRROR/current is not readable by this xbps (layout mismatch or mirror problem). Use a newer live ISO or another MIRROR.` exit 3.

Host tools are **not** installed. The ISO's base-system ships everything the installer executes on the host — `sfdisk`, `mkfs.btrfs`, `mkfs.vfat`, `lsblk`, `blkid`, `wipefs`, `udevadm`, `lspci`, `lsusb`, `loadkeys` — and that set is internally consistent. Each tool is verified with `command -v` and, where a benign call exists, executed (`--version`); a failure exits 3 with `Required tool not found on the live system: <t>` / `Required tool not usable on the live system: <t>`.

`dialog` (interactive UI only, not on the ISO) is the single exception: in interactive mode, if missing it is installed with `xbps-install -Sy dialog` (failure → `Failed to install dialog.` exit 3) and then verified. The installer itself executes no curl at all; fetching install.sh uses `xbps-fetch` (ships with xbps, present on the ISO, uses xbps's own HTTPS stack — immune to the library-skew problems of installing curl onto the old userland, and no repo transaction so no xbps-version refusal).

---

## 5. Command-line interface

```
install.sh [--config FILE] [--yes] [--help]
```

| Option | Meaning |
|---|---|
| `--config FILE` | Read settings from `FILE` (section 6). If omitted and `./install.conf` exists, use it. Otherwise no file is read |
| `--yes` | **Unattended mode.** No dialogs, no confirmation key. Every value without a default MUST be present in the config (else exit 2). `TARGET_DISK` MUST be set explicitly |
| `--help` | Print usage, exit 0 |

Any other argument: print usage, exit 2.

### 5.1 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unexpected error during installation (ERR trap) |
| 2 | Usage or configuration error (bad argument, invalid value, missing required value in `--yes` mode) |
| 3 | Preflight / package probe failed (nothing was modified on disk) |
| 4 | Aborted by the user (dialog cancelled, confirmation not `y`) |

---

## 6. Configuration

The config file is a plain `KEY=value` file. It is **parsed, never sourced**: sourcing would execute arbitrary code and would expand `$` inside values (a SHA-512 password hash such as `$6$...` would be destroyed). Parser rules (binding):

- The file MUST be a regular, readable file.
- Blank lines and lines starting with `#` are ignored.
- Every other line MUST match `^[A-Z_][A-Z0-9_]*=`. The value is everything after the first `=`. If it is wrapped in matching single or double quotes, the quotes are stripped. **No expansion of any kind** (no `$var`, no `$(...)`, no backslash handling).
- The key MUST be one of the variables in the table below; unknown keys or malformed lines → exit 2 with `Invalid config line: <line>`.
- Trailing carriage returns (files saved with Windows line endings) are stripped from every line before parsing: `line=${line%$'\r'}`.
- Assignment: `printf -v "$key" '%s' "$val"`.

Example (all valid): `HOSTNAME=void`, `HOSTNAME="void"`, `USER_PASSWORD_HASH='$6$rounds=5000$salt$hash'`.

| Variable | Required | Default | Validation | Prompted (interactive mode, if unset) |
|---|---|---|---|---|
| `TARGET_DISK` | yes | — | kernel device name `/dev/sdX`, `/dev/nvmeXnY`, `/dev/vdX`, `/dev/mmcblkX`; the value is normalised with `readlink -f` first (so `/dev/disk/by-id/...` is accepted); `lsblk -dno TYPE` = `disk`, size ≥ 20 GiB (21474836480 bytes), see 7.1 | yes, disk menu |
| `HOSTNAME` | no | `void` | `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` | yes (default prefilled) |
| `USERNAME` | yes | — | `^[a-z_][a-z0-9_-]{0,31}$`, not `root` | yes |
| `USER_PASSWORD` | yes¹ | — | non-empty | yes (twice, hidden) |
| `USER_PASSWORD_HASH` | yes¹ | — | begins with `$6$` (SHA-512 crypt) | no |
| `USER_SHELL` | no | `/bin/bash` | must be `/bin/bash` in v1 | no |
| `TIMEZONE` | no | `UTC` | file `/usr/share/zoneinfo/$TIMEZONE` exists | yes (menu of available zones) |
| `LOCALE` | no | `en_US.UTF-8` | line `#$LOCALE UTF-8` or `$LOCALE UTF-8` exists in `/etc/default/libc-locales` of the target (checked after bootstrap; preliminary check against the same file on the live system). The file is generated from glibc's `localedata/SUPPORTED`, so lines carry **trailing whitespace** — matching must tolerate it. The check is case-insensitive and accepts `.utf8` as a spelling of `.UTF-8`; the value is canonicalised to the spelling found in the file (`en_us.utf8` → `en_US.UTF-8`). Only genuinely unavailable locales are rejected | yes (menu of available locales) |
| `KEYMAP` | no | `us` | `loadkeys --parse "$KEYMAP" >/dev/null 2>&1` succeeds on the live system (parse only, does not change the live keymap) | yes (default prefilled) |
| `MIRROR` | no | `https://repo-default.voidlinux.org` | URL beginning `https://`, **no trailing slash, no `/current`** | no |
| `SWAP` | no | `zram` | `zram` or `none` | no |
| `CHEZMOI_REPO` | no | empty = skip dotfiles | `^https://[^ ]+$` or `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$` (GitHub `user/repo`) | yes (empty allowed) |
| `EXTRA_PACKAGES` | no | empty | space-separated package names, probed in step 7 | no |
| `HW_CHASSIS` | no | `auto` | `auto`, `laptop`, `desktop`, `vm` | no |
| `HW_TOUCH` | no | `auto` | `auto`, `yes`, `no` | no |
| `HW_FINGERPRINT` | no | `auto` | `auto`, `yes`, `no` | no |
| `HW_BLUETOOTH` | no | `auto` | `auto`, `yes`, `no` | no |

¹ Exactly one of `USER_PASSWORD` / `USER_PASSWORD_HASH` MUST end up set. If both are set, `USER_PASSWORD_HASH` wins.

**Prompt rules (interactive mode):**
- A variable that is unset in the config and marked "prompted" is requested via `dialog --inputbox` (or `--passwordbox` for passwords) with the default prefilled.
- `TIMEZONE` and `LOCALE` are prompted as a `dialog --menu` listing the actually-available options: the files under `/usr/share/zoneinfo` on the live system (relative path form `Europe/Berlin`, excluding `posix/`, `right/` and the tzdata metadata files) and the `UTF-8` lines of `/etc/default/libc-locales`, respectively. The current value is passed as `--default-item`. If the source list is unexpectedly empty, they fall back to `--inputbox`.
- Invalid input → show `dialog --msgbox "<reason>"` and ask again (loop until valid or Cancel).
- Cancel at any dialog → exit 4.
- A variable that is set in the config is **never** prompted, but is validated (invalid → exit 2 with message `Invalid value for <NAME>: <reason>`).

**Mode `--yes`:** unset variables take their default; variables with no default → exit 2 with `Missing required setting: <NAME>`.

`install.conf.example` MUST contain every variable above, each with a comment line giving its purpose, default and allowed values; required ones are shown uncommented with placeholder values, the rest commented out. The example for `USER_PASSWORD_HASH` MUST use single quotes (`'$6$...'`) with a comment explaining that the hash is taken literally.

---

## 7. User interface

### 7.1 Disk selection (`choose_disk`)

Only if `TARGET_DISK` is unset (interactive mode). Build the list:

Enumerate with a space-free invocation, then query size and model per device (MODEL may contain spaces):

```bash
lsblk -dpno NAME,TYPE            # candidates: lines whose TYPE is "disk"
lsblk -dno SIZE "$dev"           # human-readable size
lsblk -dno MODEL "$dev"          # model string (may be empty or contain spaces)
lsblk -dbno SIZE "$dev"          # bytes, for the minimum-size rule
```

A device is **eligible** if all of the following are true:
1. `TYPE` is `disk`
2. It is not a `loop`, `sr`, `zram`, or `ram` device
3. Neither the device nor any of its partitions has a mount point (`lsblk -no MOUNTPOINTS "$dev"` is empty for the whole tree). This excludes the live USB stick when it is mounted
4. Size ≥ 21474836480 bytes

Show the eligible devices in a single menu:

```bash
dialog --clear --title "Select target disk" \
  --menu "ALL DATA ON THE SELECTED DISK WILL BE ERASED." 20 76 10 \
  "/dev/nvme0n1" "512.1G  Samsung SSD 980" ...   3>&1 1>&2 2>&3
```

- Item text: human-readable size (`lsblk` without `-b`, same device) and model, joined by two spaces; empty model → `unknown model`.
- No eligible disk → `No eligible disk found.` exit 3.
- Cancel → exit 4.
- Exactly one eligible disk: still show the menu (no auto-selection).

If `TARGET_DISK` is set in the config it is validated with the same eligibility rules 1–4. A violation of rules 1, 2 or 4 exits with code 2 and `Invalid value for TARGET_DISK: <reason>`. A violation of rule 3 (device or one of its partitions is mounted) exits with code 2 and `Target disk or one of its partitions is mounted.`

### 7.2 Final confirmation (`confirm`)

Skipped with `--yes`. Print this block to the terminal (plain `echo`, no dialog):

```
Installation summary
  Disk:        /dev/nvme0n1  (512.1G, Samsung SSD 980)   <-- WILL BE ERASED
  Hostname:    void
  User:        alice
  Timezone:    UTC
  Locale:      en_US.UTF-8
  Keymap:      us
  Swap:        zram
  Hardware:    laptop, intel cpu, intel gpu, touchscreen
  Dotfiles:    https://github.com/alice/dotfiles
Press y to erase the disk and install, any other key aborts:
```

Read with `read -r -n1 -s answer`. `y` or `Y` → continue. Anything else → print `Aborted.` exit 4. No second confirmation, no typed word.

---

## 8. Hardware detection (`detect_hardware`)

Detection is **read-only** and MUST run before the disk is touched. Each result below becomes a shell variable (`HW_*_RESULT`) holding `yes`/`no` (or a value). A config override (`HW_CHASSIS`, `HW_TOUCH`, `HW_FINGERPRINT`, `HW_BLUETOOTH` ≠ `auto`) replaces the detected value.

### 8.1 Detection rules

| Item | Rule (evaluated in order) | Result |
|---|---|---|
| **VM** | `grep -qw hypervisor /proc/cpuinfo` | `vm` |
| **VM type** | `/sys/class/dmi/id/sys_vendor` contains `QEMU` (case-insensitive) | `qemu` (covers QEMU/KVM). Other hypervisors: VM stays `vm`, type `other` |
| **Chassis** (only if not VM) | read `/sys/class/dmi/id/chassis_type` (integer): `8 9 10 14 30 31 32` → `laptop`; `3 4 5 6 7 13 15 16 17 23 24 35 36` → `desktop`; anything else or file missing → `desktop` | `laptop` / `desktop` |
| **Convertible/tablet** | `chassis_type` ∈ `30 31 32` | `yes` |
| **CPU vendor** | `awk -F: '/vendor_id/{gsub(/ /,"",$2);print $2;exit}' /proc/cpuinfo` → `GenuineIntel` = intel, `AuthenticAMD` = amd, other = unknown | `intel` / `amd` / `unknown` |
| **GPU vendors** | `lspci -nn` lines matching `VGA compatible controller\|3D controller\|Display controller`; vendor id from `[vvvv:dddd]`: `8086` intel, `1002` amd, `10de` nvidia, `1af4`/`1b36`/`1234`/`15ad`(vmware) virtual; collect all (hybrid GPUs possible) | set of vendors |
| **Touchscreen** | any `/sys/class/input/event*` where `udevadm info -q property -p <path>` contains `ID_INPUT_TOUCHSCREEN=1` | `yes` / `no` |
| **Fingerprint reader** | `lsusb` line matches `-i 'fingerprint'`, **or** vendor id in `138a 27c6 08ff 147e 1c7a 2808 05ba` | `yes` / `no` |
| **Bluetooth** | `/sys/class/bluetooth/` contains at least one entry, **or** any `lsusb` line matches `-i 'bluetooth'` | `yes` / `no` |
| **Wi-Fi** | any directory `/sys/class/net/*/wireless` | `yes` / `no` (informational only; firmware handled below) |

Known limitation (accepted): the fingerprint rule can produce false positives (harmless: packages are installed but unused) or false negatives (user sets `HW_FINGERPRINT=yes`).

In a VM, `Touchscreen`, `Fingerprint`, and `Bluetooth` detection still run (passthrough devices are possible).

### 8.2 Package mapping (`build_package_lists`)

The function builds **one array**, `PKGS_ALL` (de-duplicated). xbps resolves each name from whichever configured repository provides it (`$MIRROR/current` and `$MIRROR/current/nonfree` are both passed), so there is no per-repository split.

**Always (all machines):**

`base-system` `linux` `linux-firmware-network` `btrfs-progs` `grub-x86_64-efi` `grub-btrfs` `grub-btrfs-runit` `efibootmgr` `dosfstools` `snapper` `inotify-tools` `NetworkManager` `dbus` `elogind` `polkit` `chrony` `sudo` `bash-completion` `acpid` `alsa-utils` `void-repo-nonfree`

**Chezmoi toolchain (always; see section 13):**

`chezmoi` `git` `curl` `wget` `openssh` `gnupg` `age` `unzip` `xz` `tar` `rsync` `python3` `base-devel` `nano`

**Conditional:**

| Condition | Main repo packages | Nonfree packages | Services enabled (section 11) |
|---|---|---|---|
| `SWAP=zram` | `zramen` | — | `zramen` |
| CPU intel | — | `intel-ucode` (nonfree, microcode follows the CPU) | — |
| CPU amd | — | — (AMD microcode ships inside `linux-firmware-amd`) | — |
| CPU **or** GPU intel | `linux-firmware-intel` | — | — |
| CPU **or** GPU amd | `linux-firmware-amd` | — | — |
| GPU intel | `mesa-dri` `vulkan-loader` `mesa-vulkan-intel` `intel-video-accel` `intel-media-driver` | — | — |
| GPU amd | `mesa-dri` `vulkan-loader` `mesa-vulkan-radeon` `mesa-vaapi` `mesa-vdpau` | — | — |
| GPU nvidia | `mesa-dri` `vulkan-loader` `mesa-nouveau-dri` (nouveau; no proprietary driver) | — | — |
| GPU virtual (VM) | `mesa-dri` | — | — |
| Intel CPU **and** chassis laptop/desktop | `sof-firmware` | — | — |
| chassis `laptop` | `tlp` `upower` `brightnessctl` `iw` | — | `tlp` `upower` |
| VM type `qemu` | `qemu-ga` `spice-vdagent` | — | `qemu-ga` `spice-vdagentd` |
| Touchscreen | `libinput` `libinput-tools` | — | — |
| Convertible/tablet **or** touchscreen on laptop | `iio-sensor-proxy` | — | `iio-sensor-proxy` |
| Fingerprint | `fprintd` `libfprint` | — | — (fprintd is D-Bus activated) |
| Bluetooth | `bluez` | — | `bluetoothd` |
| `EXTRA_PACKAGES` | each as given | — | — |

Notes:
- All packages are installed with a single `xbps-install` call (section 10.6).
- In **VM** mode the packages for `tlp`, `upower`, `brightnessctl`, `iw` (laptop row) are **not** installed (chassis is not evaluated for VMs).
- Nvidia: the installer prints, at the very end, `NVIDIA GPU detected: nouveau driver installed. Proprietary driver not included.` (the only informational message of this kind).
- Fingerprint: the installer does **not** change PAM. It prints at the end `Fingerprint reader detected: fprintd installed. Enrol with 'fprintd-enroll' and add pam_fprintd to /etc/pam.d yourself to use it for login/sudo.`

---

## 9. Disk layout (fixed)

### 9.1 Partition table

| # | Name (GPT label) | Type code (sgdisk) | Size | Filesystem | Label | Mount in target |
|---|---|---|---|---|---|---|
| 1 | `EFI` | `ef00` | 1 GiB (`+1G`) | FAT32 | `EFI` | `/boot/efi` (`umask=0077`) |
| 2 | `VOID` | `8300` | rest of disk | btrfs | `VOID` | `/` and subvolumes |

Partition device names (function `part()`):

```bash
part() {  # $1 = partition number
  case "$TARGET_DISK" in
    *[0-9]) printf '%sp%s' "$TARGET_DISK" "$1" ;;   # nvme0n1 -> nvme0n1p1, mmcblk0 -> mmcblk0p1
    *)      printf '%s%s'  "$TARGET_DISK" "$1" ;;   # sda -> sda1
  esac
}
```

### 9.2 btrfs subvolumes

| Subvolume | Mount point | Why |
|---|---|---|
| `@` | `/` | system, snapshotted by snapper |
| `@home` | `/home` | excluded from snapshots |
| `@snapshots` | `/.snapshots` | snapper storage |
| `@var_log` | `/var/log` | logs survive rollbacks |
| `@var_cache_xbps` | `/var/cache/xbps` | package cache not snapshotted |
| `@var_tmp` | `/var/tmp` | not snapshotted |

`/tmp` is a `tmpfs` entry (no subvolume).

### 9.3 Mount options

btrfs (all subvolumes): `BTRFS_OPTS="rw,noatime,compress=zstd:1,discard=async"` plus `subvol=<name>`.
ESP: `umask=0077`.

### 9.4 `/etc/fstab` (written by the installer, exactly this form)

```
UUID=<ROOT_UUID>  /                 btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@                0 0
UUID=<ROOT_UUID>  /home             btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@home            0 0
UUID=<ROOT_UUID>  /.snapshots       btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@snapshots       0 0
UUID=<ROOT_UUID>  /var/log          btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@var_log         0 0
UUID=<ROOT_UUID>  /var/cache/xbps   btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@var_cache_xbps  0 0
UUID=<ROOT_UUID>  /var/tmp          btrfs  rw,noatime,compress=zstd:1,discard=async,subvol=@var_tmp         0 0
UUID=<ESP_UUID>   /boot/efi         vfat   umask=0077                                                       0 2
tmpfs             /tmp              tmpfs  defaults,nosuid,nodev                                            0 0
```

UUIDs from `blkid -s UUID -o value "$(part 2)"` and `"$(part 1)"`.

---

## 10. Installation sequence

Pre-step state: preflight passed, live tools installed, config loaded, values validated. Steps are numbered for the progress output (`==> [N/16]`). **Steps 1–7 never modify any disk.** The destructive part starts at step 9.

Global error behavior (function `cleanup`, installed as `trap cleanup EXIT` and `trap 'on_error $LINENO' ERR`):
- `on_error` prints `Installation failed at step N (<name>), line L.` to stderr and exits 1.
- `cleanup` (runs on every exit): removes `/mnt/etc/sudoers.d/99-installer` if present; `umount -R /mnt 2>/dev/null || true`; nothing else. No retry, no resume. A re-run always starts at step 1 and wipes the disk again.

| # | Function | Action |
|---|---|---|
| 1 | `parse_args`, `load_config` | Parse CLI (5), source config (6) |
| 2 | `preflight` | Checks from section 4, install live tools |
| 3 | `detect_hardware` | Section 8.1 |
| 4 | `build_package_lists` | Section 8.2 |
| 5 | `choose_disk`, `prompt_missing` | Sections 6, 7.1 (interactive mode only) |
| 6 | `validate_all` | Validate every variable (section 6). First error → exit 2 |
| 7 | `probe_packages` | Dry-run all packages against the mirror (10.1) |
| 8 | `confirm` | Section 7.2 |
| 9 | `partition_disk` | 10.2 |
| 10 | `format_disk`, `mount_layout` | 10.3, 10.4 |
| 11 | `bootstrap_system` (prepare) | 10.5 |
| 12 | `bootstrap_system` (install) | 10.6 |
| 13 | `configure_system`, `setup_snapper`, `setup_grub`, `enable_services`, `create_user` | Sections 10.7–10.11 |
| 14 | `apply_chezmoi` | Section 13 |
| 15 | `install_wrappers`, `initial_snapshot` | Sections 12, 10.13 |
| 16 | `finalize` | 10.14 |

### 10.1 Step 7 — package probe

Create a temporary empty root and ask xbps to resolve everything without installing:

```bash
PROBE=$(mktemp -d)
mkdir -p "$PROBE/var/db/xbps/keys" "$PROBE/etc/xbps.d"
cp /var/db/xbps/keys/* "$PROBE/var/db/xbps/keys/"
XBPS_ARCH=x86_64 xbps-install -n -y -S -r "$PROBE" \
  -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
  "${PKGS_ALL[@]}"
rc=$?; rm -rf "$PROBE"
```

`rc != 0` → print `Package check failed (a package may be missing or renamed). See output above.` and exit 3. Nothing has been modified on the target disk at this point.

**Service probe (same function, directly after the package probe).** For every (package, service) pair marked *fatal* in 10.10 that applies to this machine, verify the package ships the service directory:

```bash
xbps-query -R --repository="$MIRROR/current" -f "$pkg" | grep -q "etc/sv/$svc"
```

Pairs (package → service): `dbus`→`dbus`, `elogind`→`elogind`, `polkit`→`polkitd`, `NetworkManager`→`NetworkManager`, `chrony`→`chronyd`, `acpid`→`acpid`, `grub-btrfs-runit`→`grub-btrfs`, `zramen`→`zramen` (if `SWAP=zram`). A miss → print `Package <pkg> does not provide service <svc>.` and exit 3. If `grub-btrfs-runit` does not ship a `grub-btrfs` service directory, the implementation MUST ship its own runit service (heredoc, `run` script: `#!/bin/sh` followed by `exec grub-btrfsd /.snapshots` — no `--syslog`, because v1 installs no syslog daemon (decision 18)) instead of failing; the probe result decides which path is used. Optional services (10.10) are not probed.

### 10.2 Step 9 — partitioning (destructive)

```bash
umount -R /mnt 2>/dev/null || true
swapoff -a
wipefs -af "$TARGET_DISK"
sfdisk --wipe always "$TARGET_DISK" <<'EOF'
label: gpt
size=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="VOID"
EOF
udevadm settle
```

`sfdisk` (util-linux, shipped by the ISO) replaces `sgdisk`/`partprobe` (decision 24): GPT label, type GUIDs (`ef00` ≙ EFI System Partition, `8300` ≙ Linux filesystem) and partition names are equivalent, and sfdisk triggers the kernel partition-table reread itself.

After `udevadm settle`, wait until both `$(part 1)` and `$(part 2)` exist as block devices (poll `[[ -b ... ]]` every 0.5 s, max 10 s; else fail).

### 10.3 Step 10a — filesystems

```bash
mkfs.vfat -F32 -n EFI "$(part 1)"
mkfs.btrfs -f -L VOID "$(part 2)"
ROOT_UUID=$(blkid -s UUID -o value "$(part 2)")
ESP_UUID=$(blkid -s UUID -o value "$(part 1)")
```

### 10.4 Step 10b — subvolumes and mounts

```bash
mount "$(part 2)" /mnt                       # top level (subvolid 5)
for sv in @ @home @snapshots @var_log @var_cache_xbps @var_tmp; do
  btrfs subvolume create "/mnt/$sv"
done
umount /mnt

mount -o "$BTRFS_OPTS,subvol=@" "$(part 2)" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache/xbps,var/tmp,boot/efi}
mount -o "$BTRFS_OPTS,subvol=@home"            "$(part 2)" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@var_log"         "$(part 2)" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@var_cache_xbps"  "$(part 2)" /mnt/var/cache/xbps
mount -o "$BTRFS_OPTS,subvol=@var_tmp"         "$(part 2)" /mnt/var/tmp
mount -o umask=0077 "$(part 1)" /mnt/boot/efi
```

`@snapshots` is created but **deliberately not mounted yet** (see 10.8: snapper creates a nested `.snapshots` that must be replaced).

### 10.5 Step 11 — prepare target for xbps

```bash
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
```

### 10.6 Step 12 — install packages

```bash
XBPS_ARCH=x86_64 xbps-install -S -y -r /mnt \
  -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
  "${PKGS_ALL[@]}"
```

Then, **only if** `$MIRROR` differs from `https://repo-default.voidlinux.org`, point the target at the custom mirror:

```bash
mkdir -p /mnt/etc/xbps.d
cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
sed -i "s|https://repo-default.voidlinux.org|$MIRROR|g" /mnt/etc/xbps.d/*-repository-*.conf
```

Chroot preparation (host side):

```bash
for d in dev proc sys; do
  mount --rbind "/$d" "/mnt/$d"
  mount --make-rslave "/mnt/$d"
done
cp /etc/resolv.conf /mnt/etc/resolv.conf
```

All commands in 10.7–10.11 and 13 run **in the chroot** via `chroot /mnt /bin/bash -c '<commands>'` unless marked *(host)*.

### 10.7 System configuration

```bash
# hostname
echo "$HOSTNAME" > /mnt/etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > /mnt/etc/hosts

# timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

# console keymap (Void's rc.conf)
if grep -q '^#\?KEYMAP=' /mnt/etc/rc.conf; then
  sed -i "s|^#\?KEYMAP=.*|KEYMAP=\"$KEYMAP\"|" /mnt/etc/rc.conf
else
  printf 'KEYMAP="%s"\n' "$KEYMAP" >> /mnt/etc/rc.conf
fi

# locale (glibc)
sed -i "s|^#\(${LOCALE} UTF-8\)|\1|" /mnt/etc/default/libc-locales
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
chroot /mnt xbps-reconfigure -f glibc-locales

# fstab: write exactly as in 9.4 (host side)

# sudo for group wheel
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
chmod 0440 /mnt/etc/sudoers.d/10-wheel

# root account: password locked (login only via the user + sudo)
chroot /mnt passwd -l root

# zram swap (only if SWAP=zram): MERGE into the shipped conf, never overwrite it
for kv in ZRAM_COMP_ALGORITHM=zstd ZRAM_PRIORITY=32767 ZRAM_SIZE=50 ZRAM_MAX_SIZE=8192; do
  k=${kv%%=*}; v=${kv#*=}
  if grep -q "^[# ]*export $k=" /mnt/etc/sv/zramen/conf; then
    sed -i "s|^[# ]*export $k=.*|export $k=$v|" /mnt/etc/sv/zramen/conf
  else
    echo "Warning: $k not found in shipped zramen conf, appended." >&2
    echo "export $k=$v" >> /mnt/etc/sv/zramen/conf
  fi
done
```

If `LOCALE` is not found in `/mnt/etc/default/libc-locales` → fail with `Locale not available: $LOCALE` (exit 2; this is the one validation that can only run after bootstrap, so it fires after the disk was already modified — the preliminary check in step 6 against the live system's file makes this practically unreachable).

### 10.8 snapper (`setup_snapper`, in chroot)

Order matters. `/.snapshots` is **not mounted** when this starts.

```bash
snapper --no-dbus -c root create-config /       # creates a nested subvolume /.snapshots
btrfs subvolume delete /.snapshots              # remove the nested one
mkdir /.snapshots
mount /.snapshots                               # mounts @snapshots via fstab
chmod 750 /.snapshots

snapper --no-dbus -c root set-config \
  "TIMELINE_CREATE=no" "TIMELINE_CLEANUP=no" \
  "NUMBER_CLEANUP=yes" "NUMBER_MIN_AGE=0" \
  "NUMBER_LIMIT=10" "NUMBER_LIMIT_IMPORTANT=10" \
  "EMPTY_PRE_POST_CLEANUP=no"
```

**Retention rule (binding):** at most **10 snapshot units** remain, where one `xbps-install`/`xbps-remove` transaction (a pre/post pair) counts as one unit, and the initial snapshot counts as one unit. If acceptance test T-12 shows that snapper counts the two halves of a pair separately (i.e. more than 10 pairs' worth are kept or fewer than 10 pairs remain), adjust `NUMBER_LIMIT`/`NUMBER_LIMIT_IMPORTANT` until the test passes; the observable behavior in T-12 is the requirement, not the number.

No snapper timers/cron: snapshots are created only by the wrappers (section 12) and by `initial_snapshot`.

### 10.9 GRUB (`setup_grub`, in chroot)

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
xbps-reconfigure -fa          # builds initramfs (dracut) and generates /boot/grub/grub.cfg through Void's kernel hooks
```

Required `/etc/default/grub` settings (edit with `sed` on the lines if present, else append):

```
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4"
GRUB_DISABLE_OS_PROBER=true
GRUB_TIMEOUT=3
```

`grub-btrfs` configuration is left at package defaults (it scans `/.snapshots`, the snapper standard). After editing `/etc/default/grub` run `grub-mkconfig -o /boot/grub/grub.cfg` once more. The final regeneration happens again in `initial_snapshot` (10.13) so the first snapshot appears in the menu.

### 10.10 Services (`enable_services`, host side)

runit services are enabled by symlink into the target's default runlevel:

```bash
enable_sv() {  # $1 = service, $2 = fatal|optional
  if [[ -d /mnt/etc/sv/$1 ]]; then
    ln -sf "/etc/sv/$1" "/mnt/etc/runit/runsvdir/default/$1"
  elif [[ $2 == fatal ]]; then
    echo "Service directory /etc/sv/$1 missing in target." >&2; return 1
  else
    echo "Warning: service $1 not available, skipped." >&2
  fi
}
```

| Service | Mode | Condition |
|---|---|---|
| `dbus` | fatal | always |
| `elogind` | fatal | always |
| `polkitd` | fatal | always |
| `NetworkManager` | fatal | always |
| `chronyd` | fatal | always |
| `acpid` | fatal | always |
| `grub-btrfs` | fatal | always |
| `zramen` | fatal | `SWAP=zram` |
| `tlp`, `upower` | optional | chassis laptop (not VM) |
| `qemu-ga`, `spice-vdagentd` | optional | VM type qemu |
| `iio-sensor-proxy` | optional | convertible/touch laptop |
| `bluetoothd` | optional | Bluetooth present |

`dhcpcd`, `wpa_supplicant` and any other network service MUST NOT be linked.

### 10.11 User creation (`create_user`, in chroot)

```bash
useradd -m -s /bin/bash -G wheel,audio,video,input "$USERNAME"
```

Password:
- `USER_PASSWORD_HASH` set: `printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD_HASH" | chroot /mnt chpasswd -e`
- else: `printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot /mnt chpasswd`

Passwords MUST NOT be written to any file, `ps`-visible command line, or exported into the chroot environment; they are passed on stdin only.

### 10.12 (reserved for section 13: chezmoi)

### 10.13 `initial_snapshot` (in chroot, after wrappers are installed)

```bash
snapper --no-dbus -c root create -c number -d "Initial installation"
grub-mkconfig -o /boot/grub/grub.cfg
```

### 10.14 `finalize`

```bash
rm -f /mnt/etc/sudoers.d/99-installer     # temporary NOPASSWD rule (section 13)
rm -f /mnt/etc/resolv.conf                # NetworkManager manages it at boot
umount -R /mnt
sync
```

Then print:

```
Installation complete. Remove the installation medium and reboot.
```

plus the informational lines from 8.2 (nvidia / fingerprint) and, if chezmoi failed, the chezmoi warning from section 13. The installer does **not** reboot by itself. Exit 0.

---

## 11. Target system state — summary checklist

After a successful run, a freshly booted system MUST show:

- `findmnt /` → btrfs, `subvol=/@`; `/home`, `/.snapshots`, `/var/log`, `/var/cache/xbps`, `/var/tmp` mounted from their subvolumes; `/boot/efi` is vfat
- `snapper --no-dbus -c root list` shows `Initial installation`
- The GRUB menu contains a snapshots submenu generated by grub-btrfs (its exact title is whatever grub-btrfs produces; presence of the submenu listing the snapshots is the criterion)
- `sv status /var/service/*` shows all services from 10.10 `run`
- `nmcli` works, `ping` works after connecting
- `chronyc tracking` responds
- `getent passwd root` shows locked password (`passwd -S root` → `L`)
- `swapon --show` lists `/dev/zram0` (if `SWAP=zram`)

---

## 12. xbps ↔ snapper integration (wrapper scripts)

**Constraint:** xbps has no transaction hook mechanism (unlike pacman hooks). Snapshots are therefore produced by **wrapper scripts** that shadow the real binaries.

### 12.1 Installation

One script, installed twice:

```bash
install -Dm0755 wrapper /mnt/usr/local/bin/xbps-install   # -D creates the parent directory if absent
install -Dm0755 wrapper /mnt/usr/local/bin/xbps-remove
```

The script derives its behavior from `${0##*/}`. `/usr/local/bin` precedes `/usr/bin` in Void's default `PATH` and in `sudo`'s `secure_path`; acceptance test T-9 verifies this.

The wrappers are installed in step 15, **after** the chezmoi step and **after** all package installs of the installer, so nothing during installation triggers snapshots.

### 12.2 Wrapper source (binding; embed verbatim)

```bash
#!/bin/bash
# xbps snapshot wrapper — installed as /usr/local/bin/xbps-install and /usr/local/bin/xbps-remove
cmd=${0##*/}
real=/usr/bin/$cmd
[ -x "$real" ] || { echo "$cmd: $real not found" >&2; exit 127; }

want_snapshot() {
  [ "$(id -u)" -eq 0 ] || return 1
  [ -z "${XBPS_NO_SNAPSHOT:-}" ] || return 1
  [ -r /etc/snapper/configs/root ] || return 1
  local argch pkgs=0 act=0 opt c
  case $cmd in
    xbps-install) argch=CcrR ;;   # short options that take an argument
    xbps-remove)  argch=Ccr  ;;   # (-R is a plain flag for xbps-remove)
    *) return 1 ;;
  esac
  while [ $# -gt 0 ]; do
    case $1 in
      --) shift; pkgs=$((pkgs + $#)); break ;;
      --rootdir|--rootdir=*|--dry-run|--download-only|--help|--version) return 1 ;;
      --update) [ "$cmd" = xbps-install ] && act=1 ;;
      --remove-orphans) [ "$cmd" = xbps-remove ] && act=1 ;;
      --config|--cachedir|--repository) shift ;;
      --*) ;;
      -?*)
        opt=${1#-}
        while [ -n "$opt" ]; do
          c=${opt:0:1}; opt=${opt:1}
          case $c in
            n|D|h|V|r) return 1 ;;   # dry-run, download-only, help, version, other rootdir
            u) [ "$cmd" = xbps-install ] && act=1 ;;
            o) [ "$cmd" = xbps-remove ]  && act=1 ;;
          esac
          case $argch in
            *"$c"*) [ -z "$opt" ] && shift; opt= ;;   # option consumes the rest, or the next word
          esac
        done ;;
      *) pkgs=$((pkgs + 1)) ;;
    esac
    shift
  done
  [ $((pkgs + act)) -gt 0 ]
}

if want_snapshot "$@"; then
  desc="$cmd $*"
  pre=$(snapper --no-dbus -c root create -t pre -p -c number -d "$desc" 2>/dev/null) || pre=
  [ -n "$pre" ] || echo "warning: could not create pre snapshot, continuing without snapshot" >&2
  "$real" "$@"; rc=$?
  if [ -n "$pre" ]; then
    snapper --no-dbus -c root create -t post --pre-number "$pre" -c number -d "$desc" >/dev/null 2>&1 \
      || echo "warning: could not create post snapshot" >&2
    snapper --no-dbus -c root cleanup number >/dev/null 2>&1 || true
  fi
  exit $rc
fi
exec "$real" "$@"
```

### 12.3 Behavior table (binding)

| Invocation | Snapshot? |
|---|---|
| `xbps-install -Su` / `-Syu` | yes |
| `xbps-install -S` (sync only) | no |
| `xbps-install -S foo` / `xbps-install foo` | yes |
| `xbps-install -n foo`, `--dry-run`, `-D` / `--download-only`, `-h`, `-V` | no |
| `xbps-install -r /other/root ...` | no |
| `xbps-remove foo` / `-R foo` / `-o` (orphans) | yes |
| `xbps-remove -O` (cache cleanup only) | no |
| any call as non-root | no (xbps itself will fail for lack of permissions) |
| `XBPS_NO_SNAPSHOT=1 xbps-install ...` | no |
| snapper missing or `root` config missing | no, command runs normally |

- The wrapper MUST always return the real command's exit status and MUST never prevent the package operation (a snapshot error is a warning only).
- Only `/` is snapshotted. `/home`, `/var/log`, the xbps cache and `/var/tmp` are separate subvolumes and are not part of any snapshot.
- Snapper creates **read-only** snapshots by default (do not pass `--read-write`); grub-btrfs boots the chosen snapshot with its stored mount options. Test T-14 asserts `ro`. That is sufficient for inspection/rescue. Writable overlay boot and `snapper rollback` workflows are out of scope for v1 and MUST NOT be implemented or documented as supported.
- Any manual use of `xbps-reconfigure`, `xbps-alternatives` etc. is not snapshotted (accepted).
- If a transaction is interrupted (power loss, Ctrl-C of the wrapper) the *pre* snapshot has no matching *post* snapshot. This is accepted: the orphan is removed by the normal number cleanup, or manually with `snapper -c root delete <number>`. No signal handling in the wrapper in v1.

---

## 13. chezmoi dotfiles (`apply_chezmoi`)

Runs in step 14, after the user exists and all packages are installed, before the wrappers are installed.

**Skipped** if `CHEZMOI_REPO` is empty (continue silently).

Because bootstrap scripts often run `sudo` (e.g. `sudo xbps-install`), the user gets a **temporary** passwordless sudo rule for the duration of this step:

```bash
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" > /mnt/etc/sudoers.d/99-installer
chmod 0440 /mnt/etc/sudoers.d/99-installer
```

Run:

```bash
chroot /mnt su - "$USERNAME" -c "chezmoi init --apply --force '$CHEZMOI_REPO'" </dev/null
```

Then remove `/mnt/etc/sudoers.d/99-installer` immediately (also removed again in `finalize` and in `cleanup`, so an error can never leave it behind).

**Failure policy:** a non-zero exit from chezmoi is **not fatal**. The installer sets `CHEZMOI_FAILED=1`, continues, and prints at the end:

```
Warning: chezmoi failed. After first boot run:  chezmoi init --apply <CHEZMOI_REPO>
```

Rationale: bootstrap scripts may assume a running system (running runit, session D-Bus, GUI session) which a chroot cannot provide; they are re-runnable by design.

**Non-interactive rules:** `--force` makes chezmoi overwrite without prompting (the new home already contains skeleton files such as `.bashrc` that a managed dotfile may replace), and stdin is `/dev/null` so nothing can wait for input. There is no TTY in this step.

**Constraints (v1):**
- The repository MUST be publicly readable via HTTPS (or `user/repo` on GitHub). SSH URLs and tokens are not supported.
- The installer does not inspect or modify the contents of the dotfiles repository.
- No timeout is applied to the chezmoi run.

---

## 14. Safety rules (binding)

1. Nothing destructive happens before the confirmation (interactive) or before step 9 (`--yes`). The probe in step 7 guarantees packages resolve before the disk is wiped.
2. The target disk is never chosen automatically and never from a default.
3. Only whole-disk install exists; the script MUST NOT touch any other disk.
4. Secrets (passwords) are never written to disk by the installer outside `/etc/shadow` (via `chpasswd`), never echoed, never in the process list.
5. `/mnt` is unmounted (`umount -R /mnt`) on every exit path.
6. The ESP is mounted with `umask=0077` and the btrfs `/.snapshots` has mode `750`.

---

## 15. Test plan

### 15.1 Phase 1 — QEMU/KVM (reference environment)

Prepare once: `qemu-img create -f qcow2 void-test.qcow2 40G`, OVMF firmware (`OVMF_CODE.fd` + a private writable copy of `OVMF_VARS.fd`). Boot example:

```bash
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=void-test.qcow2,if=virtio \
  -cdrom void-live-x86_64-*.iso -boot d \
  -nic user,model=virtio-net-pci -device virtio-vga \
  -serial stdio   # capture console output; the installer itself writes no log
```

`-machine q35` is recommended for a more laptop-like platform.

| ID | Test | Expected |
|---|---|---|
| T-1 | Run in BIOS mode (no OVMF) | exit 3, message `Not booted in UEFI mode.` |
| T-2 | Run without network | exit 3, nothing written to disk |
| T-3 | Interactive run, defaults | disk menu lists only the qcow2 disk; confirmation with `y` installs; reboot succeeds into GRUB then login prompt |
| T-4 | Press `n` at confirmation | exit 4, disk unchanged |
| T-5 | `--yes --config install.conf` fully specified | unattended install, same result as T-3 |
| T-6 | `--yes` with `USERNAME` missing | exit 2, message `Missing required setting: USERNAME` |
| T-7 | `EXTRA_PACKAGES="doesnotexist"` | exit 3 at step 7, disk unchanged |
| T-8 | After first boot: checklist from section 11 | all items true |
| T-9 | `command -v xbps-install` as user and in `sudo sh -c 'command -v xbps-install'` | both print `/usr/local/bin/xbps-install` |
| T-9b | `lsattr -d /boot` and `findmnt -no OPTIONS /` | no special `/boot` handling is required: root is mounted with `compress=zstd:1` and GRUB boots (see decision 17) |
| T-10 | `sudo xbps-install -S htop` | one new pre/post pair appears in `snapper list`; grub-btrfs menu regenerates (inotify service) |
| T-11 | `sudo xbps-install -n htop`, `sudo xbps-install -S`, `sudo xbps-remove -O` | no new snapshot |
| T-12 | Run 12 install/remove transactions | at most 10 snapshot units remain (see 10.8); oldest are deleted; `Initial installation` is eventually removed |
| T-13 | Kernel update (`xbps-install -Su` with a newer kernel available, or `xbps-reconfigure -fa`; note `xbps-reconfigure -f linux` only touches the meta package and does not run kernel hooks) | grub.cfg regenerated, system still boots, snapshot taken |
| T-14 | Boot a snapshot entry from the GRUB snapshots submenu | system boots; `findmnt -no OPTIONS /` contains `ro` |
| T-15 | `CHEZMOI_REPO` set to a public test repo with a bootstrap script | files present in `$HOME`, bootstrap effects visible; no `99-installer` sudoers file remains |
| T-16 | `CHEZMOI_REPO` set to a nonexistent repo | installer completes, prints the chezmoi warning, exit 0 |
| T-17 | VM detection | `qemu-ga` and `spice-vdagentd` services exist and are `run`; no `tlp` |
| T-18 | `SWAP=none` | no zram, no `zramen` service |
| T-19 | `sudo` as the new user | works with password; root login is locked |
| T-20 | Reboot persistence | NVRAM boot entry `Void` survives power cycle (OVMF_VARS file kept) |
| T-21 | Config with `USER_PASSWORD_HASH='$6$...'` (single-quoted) | install completes; user can log in with the matching password |
| T-22 | Custom `MIRROR` (e.g. a regional mirror base URL) | install completes; target `/etc/xbps.d/*-repository-*.conf` contain the custom mirror; `xbps-query -L` in target agrees |
| T-23 | Invalid config value (`HOSTNAME="Bad Host!"`) and an unknown key | exit 2 with `Invalid value for HOSTNAME: ...` / `Invalid config line: ...` |
| T-24 | Run the installer a second time on the already installed disk | wipes cleanly, installs again, exit 0 |
| T-25 | `TARGET_DISK=/dev/disk/by-id/<qcow2 disk>` | normalised, install completes |
| T-26 | Config with `$` in a value other than the hash, e.g. `HOSTNAME='a$b'` | rejected by validation (exit 2), never expanded |
| T-27 | After first boot with network: `getent hosts voidlinux.org` and `cat /etc/resolv.conf` | name resolution works; `/etc/resolv.conf` is written by NetworkManager |

### 15.2 Phase 2 — physical laptop

Run only after all Phase 1 tests pass. Same install, then verify:

| ID | Test | Expected |
|---|---|---|
| L-1 | Wi-Fi via NetworkManager | `nmcli device wifi connect ...` succeeds after reboot |
| L-2 | Detection output matches reality | summary block lists laptop, correct CPU/GPU vendor, touchscreen/fingerprint iff present |
| L-3 | Power management | `tlp-stat -s` shows TLP active; `upower -e` lists the battery |
| L-4 | Brightness | `brightnessctl` changes backlight |
| L-5 | Lid close/suspend | `loginctl suspend` works; wakes correctly |
| L-6 | Fingerprint (if present) | `fprintd-list $USER` lists the device; `fprintd-enroll` completes |
| L-7 | Touchscreen (if present) | `libinput list-devices` shows it |
| L-8 | GPU acceleration | after `xbps-install libva-utils vulkan-tools` (test tooling is not part of the install), `vainfo` / `vulkaninfo --summary` report the expected GPU |
| L-9 | Bluetooth (if present) | `bluetoothctl list` shows a controller |
| L-10 | NVRAM/boot | machine boots from internal disk with the installation medium removed |

Any laptop-specific failure is documented as an issue and fixed in the detection/package tables (sections 8.1 / 8.2), not with ad-hoc special cases in code.

---

## 16. Author decisions beyond the customer's answers (fixed for v1)

Listed so they can be changed on purpose. The implementation follows them as written.

1. **UEFI only.** BIOS boot aborts.
2. **Bash and `dialog`** (not POSIX sh, not whiptail).
3. **Kernel:** `linux` meta-package, not LTS.
4. **Root is locked;** the user is in `wheel` with `sudo` (not doas).
5. **Time sync:** `chrony`; **laptop power:** `tlp` + `upower`; **audio:** only `alsa-utils` (+ `sof-firmware` on Intel). No PipeWire/compositor/login manager — expected to come from the dotfiles bootstrap.
6. **zram:** `zramen`, zstd, 50 % of RAM, capped at 8192 MiB, priority 32767.
7. **btrfs options:** `noatime,compress=zstd:1,discard=async`.
8. **No PAM changes** for fingerprint login; the user enrols manually.
9. **NVIDIA:** nouveau only.
10. **Only `/` is snapshotted;** `/home` is not.
11. **Snapshots boot read-only;** no rollback tooling.
12. **Snapper cleanup runs inside the wrapper** (no timers/cron), minimum age 0.
13. **Default timezone `UTC`, locale `en_US.UTF-8`, keymap `us`, hostname `void`.**
14. **Mirror** configurable but only the base URL (the installer appends `/current`).
15. **Chezmoi runs in the chroot with temporary passwordless sudo**; failure is non-fatal.
16. **Limine** is explicitly out of scope; revisit when snapshot menu and kernel-update hooks are available for it on Void.
17. **No special handling of `/boot` for compression.** GRUB has read zstd-compressed btrfs since 2.04, so `/boot` stays on the compressed `@` subvolume (no NOCOW flag).
18. **No firewall and no syslog daemon in v1.** `openssh` is installed but no SSH server is enabled. Kernel messages remain available through `dmesg`. Both can be added through the dotfiles bootstrap or `EXTRA_PACKAGES`.
19. **Fingerprint:** packages `fprintd`/`libfprint` are installed; PAM (which Void does use) is left untouched. The user wires up `pam_fprintd` and enrols manually.
20. **Config is parsed, not sourced** (section 6).
21. **Users are not added to the `network` group** (elogind + polkit grant NetworkManager access to local sessions).
22. **Root recovery:** root is locked and `sudo` is the only escalation path. If the user's password is lost, recovery means booting the live ISO, mounting the subvolumes as in 10.4, chrooting and running `passwd`. The README MUST state this.
23. **Self-healing, zero-install preflight:** the live ISO ships no curl, no dialog and an outdated xbps. Preflight self-updates xbps, verifies the ISO's **native** tools instead of installing packages over the old userland (library skew → `symbol lookup error`; a full sync needs ~2.5 GiB and does not fit in the ISO's RAM-backed root), and uses bash `/dev/tcp` for the network check. `dialog` (not on the ISO) is installed on demand in interactive mode. Fetching install.sh uses `xbps-fetch` — part of xbps, shipped on the ISO, own HTTPS stack, no repo transaction; no curl anywhere.
24. **sfdisk instead of sgdisk:** partitioning uses util-linux `sfdisk`, shipped by the ISO — GPT label, type GUIDs and partition names equivalent to `sgdisk -n/-t/-c`, and it re-reads the partition table itself (no `partprobe`, no gptfdisk/parted install). The `udevadm settle` plus device-poll loop stays.

---

## 17. Acceptance criteria for v1

The installer is accepted when:

- ShellCheck is clean;
- all tests T-1 … T-20 pass in QEMU;
- all tests L-1 … L-10 that apply to the available hardware pass on the laptop;
- a developer other than the author can reproduce a bootable system from this document alone without making any design decision that is not written here.

# Void Linux Installer

A single-file Bash installer for Void Linux (glibc, x86_64, UEFI). It wipes
one whole disk and installs a complete, bootable base system with:

- GPT + ESP (1 GiB) + btrfs (`@`, `@home`, `@snapshots`, `@var_log`,
  `@var_cache_xbps`, `@var_tmp`, compressed with zstd)
- GRUB with a bootable snapshot menu (grub-btrfs)
- snapper snapshots around every `xbps-install` / `xbps-remove` transaction
  (last 10 kept) via wrapper scripts in `/usr/local/bin`
- NetworkManager, chrony, runit services, hardware detection with matching
  drivers/firmware
- Wayfire, wf-shell and kitty with a panel, terminal launcher and keyboard
  layout derived from the selected console keymap
- greetd with tuigreet on tty7, native session selection and remembered
  user/session; tty1 stays available for console recovery
- one sudo-enabled user account and a separate root password for console
  recovery and, optionally,
  chezmoi-managed dotfiles from a public GitHub repository

The installer verifies that `/mnt` is clear before starting, refuses disks
that are mounted, read-only, or held by another block device, and only
unmounts paths it mounted itself. Implementation and test progress is tracked
in `IMPLEMENTATION_PROGRESS.md`.

Package and service probes synchronize repository metadata once into a
temporary isolated cache before disk changes. The installer removes that
cache after probing and still performs full dependency and disk-space planning
against the mounted target before package installation.

The desktop baseline works without dotfiles. Existing user configuration files
are preserved if desktop configuration is retried.

## Requirements

- the **official Void Linux live ISO (glibc, x86_64)**, booted in **UEFI**
  mode with Secure Boot disabled, and a working network connection
- a target disk of **at least 20 GiB** — it will be **completely erased**
- at least 1 GiB RAM

## Usage

Fetch and run (you are root on the live ISO; `xbps-fetch` ships with xbps,
so this needs no curl and installs nothing):

```sh
xbps-fetch https://raw.githubusercontent.com/noeltz/n0_void-installer/main/install.sh && bash install.sh
```

To verify integrity, fetch with `-s` instead and compare the printed SHA-256
with the checksum published next to the script:

```sh
xbps-fetch -s https://raw.githubusercontent.com/noeltz/n0_void-installer/main/install.sh
```

Interactive run (disk selection and remaining values via dialogs):

```sh
bash install.sh
```

Unattended — every required value must come from the config file:

```sh
sudo cp install.conf.example install.conf
${EDITOR:-vi} install.conf
sudo bash install.sh --yes --config install.conf
```

If an installation stops after formatting the target, boot the live ISO again
and resume from its Btrfs root partition (for example `/dev/sda2`). Resume
checks the saved installer version and the root/EFI UUIDs before continuing:

```sh
bash install.sh --resume /dev/sda2
```

To inspect or repair an existing installation without formatting it, use:

```sh
bash install.sh --repair /dev/sda2
```

Repair mode offers a system check, target chroot, account password reset, GRUB
reinstall, or initramfs regeneration. Actions can also be selected directly,
such as `--repair /dev/sda2 --action password --user root`. Resume and repair
require the target disk to be unmounted and `/mnt` to be empty.

All settings, defaults and validation rules are documented in
`install.conf.example`.

## After installation

Remove the installation medium and reboot. Log in through tuigreet on tty7
with the configured user and password; F3 selects Wayfire or another installed
session. That user can use `sudo`; root can also log in on tty1 with
the separate root password configured during installation.

Use Ctrl+Alt+F1 for the recovery console and Ctrl+Alt+F7 to return to greetd.
Selected Wayland sessions run under `dbus-run-session --` without modifying
their native session files. To start Wayfire manually from the console, use
`dbus-run-session -- wayfire`.
Super+Enter opens kitty, Super+Q closes a window, Alt+Tab switches windows,
Super+arrow tiles windows, and Super+Escape logs out. The panel also provides
an application menu, kitty launcher, network status, battery and clock.
`KEYMAP` controls both console and desktop layouts. Common named console maps
(including German, French, British, Brazilian and Dvorak) have explicit XKB
conversions; unknown or custom maps are rejected before disk changes.

When a chezmoi repository is configured, setup runs on the user's first
interactive tty login by default. If it fails or is interrupted, retry with
`void-installer-chezmoi --retry`. Set `CHEZMOI_MODE=install` in the installer
configuration to use installation-time setup instead.

For Wi-Fi-only devices, configure an optional SSID and WPA-Personal password
in `install.conf` (or choose a network interactively). The installer writes a
root-only NetworkManager profile for first boot; the live ISO still requires
an independent working connection during installation.

### Recovery if a password is lost

If the user's password is lost, log in as root on tty1 and run `passwd youruser`.
If both passwords are lost, boot the live ISO and reset them from a chroot:

```sh
mount -o subvol=@ /dev/sdX2 /mnt          # adjust the disk
for d in dev proc sys; do mount --rbind /$d /mnt/$d; done
chroot /mnt passwd youruser
chroot /mnt passwd root
```

## Development

The installer implements `installer_spec.md` (binding specification).
ShellCheck must pass cleanly, including on the embedded xbps wrapper
(extracted and checked separately in CI).

Desktop configuration and checkpoint failure checks run without a VM:

```sh
python3 tests/desktop-regression.py
python3 tests/greetd-regression.py
python3 tests/resume-repair-regression.py
python3 tests/installer-state-regression.py
```

Run the isolated XBPS bootstrap regression test on a Void system with Python 3
and OpenSSL available:

```sh
python3 tests/bootstrap-regression.py
```

It serves a signed fixture repository on localhost and uses a temporary target
to reproduce the `-n -S` failure and verify separate synchronization followed
by a dry-run. It also confirms cached package/service queries do not refetch
repository indexes. It installs no packages and requires no root privileges.

The account regression test reproduces a PAM password update that returns
success without setting a password, then checks that explicit SHA-512 updates
write matching hashes for both user and root. It modifies only temporary account
files. Run it on Void as root or in a user namespace:

```sh
unshare --user --map-root-user python3 tests/account-password-regression.py
```

Cleanup and state regression tests run without a Void installation or root:

```sh
python3 tests/cleanup-regression.py
python3 tests/installer-state-regression.py
python3 tests/boot-regression.py
python3 tests/chezmoi-regression.py
python3 tests/wifi-regression.py
```

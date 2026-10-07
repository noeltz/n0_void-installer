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

No desktop environment or login manager is installed — that is expected to
come from your dotfiles.

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

All settings, defaults and validation rules are documented in
`install.conf.example`.

## After installation

Remove the installation medium and reboot. Log in with the configured user and
password. That user can use `sudo`; root can also log in on the console with
the separate root password configured during installation.

When a chezmoi repository is configured, setup runs on the user's first
interactive tty login by default. If it fails or is interrupted, retry with
`void-installer-chezmoi --retry`. Set `CHEZMOI_MODE=install` in the installer
configuration to use installation-time setup instead.

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
```

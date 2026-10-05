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
- one sudo-enabled user account (root stays locked) and, optionally,
  chezmoi-managed dotfiles from a public GitHub repository

No desktop environment or login manager is installed — that is expected to
come from your dotfiles.

## Requirements

- the **official Void Linux live ISO (glibc, x86_64)**, booted in **UEFI**
  mode, with a working network connection
- a target disk of **at least 20 GiB** — it will be **completely erased**
- at least 1 GiB RAM

## Usage

One-liner straight from the repo (you are root on the live ISO). The ISO
ships neither a current xbps nor curl — the first two commands fix that
(the script also handles both itself if you transfer it another way):

```sh
xbps-install -Syu xbps && xbps-install -Sy curl && bash <(curl -fL github.com/noeltz/n0_void-installer/raw/main/install.sh)
```

Or download the script (and the SHA-256 checksum published next to it) on the
live ISO and verify before running:

```sh
curl -fLO https://<where-the-script-is-published>/install.sh
sha256sum -c install.sh.sha256    # or compare with the published checksum
```

Interactive (disk selection and remaining values via dialogs):

```sh
sudo bash install.sh
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

Remove the installation medium and reboot. Log in as the configured user;
`sudo` works with that user's password (root's password is locked).

### Recovery if the user password is lost

Root is locked, so recovery requires the live ISO:

```sh
mount -o subvol=@ /dev/sdX2 /mnt          # adjust the disk
for d in dev proc sys; do mount --rbind /$d /mnt/$d; done
chroot /mnt passwd youruser
```

## Development

The installer implements `installer_spec.md` (binding specification).
ShellCheck must pass cleanly, including on the embedded xbps wrapper
(extracted and checked separately in CI).

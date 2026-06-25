# Void Linux Installation Script

This is a simple script that uses [fzf](https://github.com/junegunn/fzf) in most places for browsing lists and a CLI for easy installation of the system with the BTRFS file system and an out-of-the-box setup.

 **WARNING**: this is an installation for the **x86_64** platform only.

 > *This is a personal project, primarily intended for my own needs. However, I have tried to make it reasonably universal to a certain extent.*
 ***

 <a href="https://voidlinux.org/">
   <img src="https://voidlinux.org/assets/img/void_bg.png" alt="voidlinux_logo" width="190px" height="190px">
</a>

<a href="https://github.com/niri-wm/niri">
   <img src="https://niri-wm.github.io/niri/_assets/icons/logo.svg" alt="niri_logo" width="200px" height="200px">
</a>

<a href="https://noctalia.dev/">
   <img src="https://assets.noctalia.dev/noctalia-logo.svg" alt="noctalia_logo" width="200px" height="200px">
</a>

 ***

### What the script can do:

 - Format a user-selected disk
 - Create a BTRFS file system for data *(Not yet configurable)*
1. - @snapshots
2. - @home
3. - UEFI partition with 1GB
 -  Install Void Linux onto the selected disk
 - Create a user and add them to the basic groups *(Not yet configurable)*
 - Set up locales, timezone and keyboard according to the user
 -  Configure Wayland
 -  Set up Niri + Noctalia
 -  Configure sound, bluetooth and more

### What the script cannot do (yet):
 - Set up automatic snapshots and access from GRUB
 - Automatically choose between EFI and UEFI version based on how the system was booted
 
 The result should be an out-of-the-box experience with Void Linux and the Niri graphical environment.
 
### Installation
The installation is designed to be run from a Void Linux live-image [Glibc version], available [here.](https://repo-default.voidlinux.org/live/current/void-live-x86_64-20250202-base.iso)

Log in as ``root``:``voidlinux`` and follow the installation instructions:

```bash
xbps-install -Suy xbps git
git clone https://github.com/noeltz/n0_void-installer.git
cd n0_void-installer/
./install.sh
```

#!/bin/bash

INSTALLER_DIR="n0_void-installer"

source ./base.sh
source ./hardware.sh
source ./post.sh

clear
separator -iwi
figlet "VOID Linux Installer"
separator -iwi
sleep 2

listDisk				# List connected disks
diskFormat				# Format disks and set up partitions + BTRFS
installSystem				# Install the base system
detectHardware				# Detect hardware -> hardware-packages.txt + hardware-services.txt
mkdir -p /mnt/$INSTALLER_DIR		# Create and copy scripts for installation inside the CHROOT
cp -r * /mnt/$INSTALLER_DIR/

clear
separator -iwi
figlet "Entering CHROOT"
separator -iwi
sleep 2

xchroot /mnt /bin/bash -c "cd /$INSTALLER_DIR; ./chroot.sh"

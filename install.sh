#!/bin/bash

INSTALLER_DIR="void-installer"

source ./base.sh
source ./post.sh

clear
separator -iwi
figlet "VOID Linux Installer" 
separator -iwi
sleep 2

listDisk				# List connected disks
diskFormat				# Format disks and set up partitions + BTRFS 
installSystem				# Install the base system
mkdir -p /mnt/void-installer		# Create and copy scripts for installation inside the CHROOT
cp -r * /mnt/void-installer/

clear
separator -iwi
figlet "Entering CHROOT"
separator -iwi
sleep 2

xchroot /mnt /bin/bash -c 'cd /void-installer; ./chroot.sh'

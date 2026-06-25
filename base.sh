#!/bin/bash
set -e

installCheck() {		#Installs missing packages
  missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  printf "Installing missing: %s\n" "${missing[*]}" >&2
  xbps-install -Sy "${missing[@]}"
}
efiCheck() {			# Detects whether the system booted via UEFI or BIOS
    [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
}
separator() {			# Function for drawing separators
    OPTIND=1
    local OPTION
    while getopts 'iw' OPTION; do
        case $OPTION in
        i)
            for ((s=0;s<$(tput cols);s++))
            do
                printf "="
            done
            ;;
        w)
            for ((s=0;s<$(tput cols);s++))
            do
                printf "!"
            done
            ;;
        esac
    done
}
listDisk() {
    separator -i
    figlet "DISKS"
    lsblk -d -o NAME,SIZE,MOUNTPOINTS
    separator -i
    read -r -n 1 -p "Press any key to select a disk..."
    DISK=$(lsblk -dn -o NAME | fzf)
}
diskFormat() {
    separator -i
    figlet "DISK FORMATTING"
    separator -i
    sleep 1

    while true; do
        separator -iwi
	read -p "Are you sure you want to format disk $DISK $(sfdisk -l /dev/$DISK | grep 'Disk model:') [yes/no]?: " FORMAT_ANSWER
        if [ $FORMAT_ANSWER = "yes" ] ; then
            break
        else
            listDisk
        fi
    done

    DISK_PATH="/dev/$DISK"
    cat > /tmp/parts.sfdisk <<'EOF'
label: gpt
,1G,C12A7328-F81F-11D2-BA4B-00A0C93EC93B,
,,0FC63DAF-8483-4772-8E79-3D69D8477DE4,
EOF
   sfdisk $DISK_PATH < /tmp/parts.sfdisk

   clear
   separator -iwi
   echo "The disk has been formatted as follows:"
   separator -i
   cat << EOF
   Disk size:       $(lsblk $DISK_PATH -nl -o SIZE | head -n 1 | tail -n 1)
   EFI partition:   $(lsblk $DISK_PATH -nl -o SIZE | head -n 2 | tail -n 1)
   BTRFS partition: $(lsblk $DISK_PATH -nl -o SIZE | head -n 3 | tail -n 1)
EOF
    echo
    read -r -n 1 -p "Press any key to continue..." -s
    clear

   parts=($(lsblk $DISK_PATH -ln -o PATH,TYPE | awk '$2=="part"{print $1}'))
   separator -iwi
   echo "Formatting disk ${parts[0]} as FAT"
   separator -iwi
   mkfs.vfat -F32 "${parts[0]}"
   separator -iwi
   echo "Formatting disk ${parts[1]} as BTRFS"
   separator -iwi
   mkfs.btrfs -f "${parts[1]}"
   
   btrfsFunc
}
btrfsFunc() {
    separator -i
    figlet "FILESYSTEM CREATION"
    separator -i
    sleep 1
    BTRFS_OPT="noatime,compress=zstd"

    mount ${parts[1]} /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    umount /mnt

    mount -o $BTRFS_OPT,subvol=@ ${parts[1]} /mnt
    mkdir -p /mnt/home
    mkdir -p /mnt/.snapshots
    mkdir -p /mnt/boot/efi/
    mount -o $BTRFS_OPT,subvol=@home ${parts[1]} /mnt/home
    mount -o $BTRFS_OPT,subvol=@snapshots ${parts[1]} /mnt/.snapshots
    mount ${parts[0]} /mnt/boot/efi

}
installSystem() {
    separator -i
    figlet "SYSTEM INSTALLATION"
    separator -i
    sleep 1

    REPO="https://repo-de.voidlinux.org/current"
    ARCH="x86_64"

    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

    XBPS_ARCH=$ARCH xbps-install -Sy -r /mnt -R "$REPO" base-system
    xgenfstab -U /mnt > /mnt/etc/fstab
}

xbps-install -Suy xbps
installCheck fzf grep figlet

#!/bin/bash
# void-installer.sh - Complete Guided Void Linux Installer (Final Fixes)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ==========================================
# STEP 1 to 4 (Pre-flight, Partition, Mount, Install)
# ==========================================
check_root() { [[ $EUID -ne 0 ]] && { log_error "Must be root"; exit 1; }; }
detect_boot_mode() { [[ -d /sys/firmware/efi ]] && BOOT_MODE="efi" || BOOT_MODE="bios"; }
detect_arch() { ARCH=$(uname -m); case "$ARCH" in x86_64) VOID_ARCH="x86_64";; aarch64) VOID_ARCH="aarch64";; *) VOID_ARCH="$ARCH";; esac; }
check_internet() { ping -c 1 -W 3 1.1.1.1 &> /dev/null && INTERNET_OK=true || INTERNET_OK=false; }

select_target_disk() {
    log_step "Detecting available physical disks..."
    declare -a DISK_NAMES; local i=1
    while read -r name size model; do DISK_NAMES+=("$name"); printf "  %d) %-10s %-8s %s\n" "$i" "$name" "$size" "$model"; ((i++)); done < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|nvme|vd|hd|mmcblk)')
    if [[ ${#DISK_NAMES[@]} -eq 0 ]]; then log_error "No disks found!"; exit 1; fi
    local max_choice=$i; echo "  $max_choice) Cancel"
    while true; do
        read -p "Select target disk [1-$max_choice]: " choice
        if [[ "$choice" == "$max_choice" ]]; then exit 0;
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < max_choice )); then
            TARGET_DISK="/dev/${DISK_NAMES[$((choice-1))]}"; log_info "Selected: $TARGET_DISK"; break
        else log_warn "Invalid selection."; fi
    done
}

confirm_wipe() {
    echo -e "${RED}WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
    read -p "Type 'WIPE' to confirm: " CONFIRM; [[ "$CONFIRM" != "WIPE" ]] && exit 1
}

partition_disk() {
    wipefs -a "$TARGET_DISK" > /dev/null
    [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]] && PART_PREFIX="p" || PART_PREFIX=""
    if [[ "$BOOT_MODE" == "efi" ]]; then
        sfdisk --wipe=always "$TARGET_DISK" <<< "label: gpt\nsize=512M, type=uefi\ntype=linux" > /dev/null
        TARGET_EFI="${TARGET_DISK}${PART_PREFIX}1"; TARGET_ROOT="${TARGET_DISK}${PART_PREFIX}2"
    else
        sfdisk --wipe=always "$TARGET_DISK" <<< "label: dos\ntype=83, bootable" > /dev/null
        TARGET_ROOT="${TARGET_DISK}${PART_PREFIX}1"
    fi
    partprobe "$TARGET_DISK" 2>/dev/null || true; sleep 2
}

format_filesystems() {
    [[ "$BOOT_MODE" == "efi" ]] && mkfs.vfat -F 32 "$TARGET_EFI" > /dev/null
    mkfs.ext4 -F "$TARGET_ROOT" > /dev/null
}

mount_filesystems() {
    mkdir -p /mnt; mount "$TARGET_ROOT" /mnt
    if [[ "$BOOT_MODE" == "efi" ]]; then mkdir -p /mnt/boot/efi; mount "$TARGET_EFI" /mnt/boot/efi; fi
}

mount_virtual_filesystems() {
    mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run
    mount --rbind /dev /mnt/dev; mount --make-rslave /mnt/dev
    mount -t proc /proc /mnt/proc
    mount --rbind /sys /mnt/sys; mount --make-rslave /mnt/sys
    mount --rbind /run /mnt/run; mount --make-rslave /mnt/run
}

select_libc() {
    echo "  1) glibc (Recommended)  2) musl"
    while true; do
        read -p "Enter choice [1-2] (default: 1): " choice; choice=${choice:-1}
        case $choice in
            1) LIBC="glibc"; VOID_ARCH_SUFFIX=""; break ;;
            2) LIBC="musl"; VOID_ARCH_SUFFIX="-musl"; break ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
    FULL_ARCH="${VOID_ARCH}${VOID_ARCH_SUFFIX}"
    REPO="https://repo-default.voidlinux.org/current"
}

install_base_system() {
    mkdir -p /mnt/var/db/xbps/keys; cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
    XBPS_ARCH="$FULL_ARCH" xbps-install -S -y -r /mnt -R "$REPO" base-system linux kbd
}

prepare_chroot() {
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf
    xbps-reconfigure -r /mnt -f base-files >/dev/null 2>&1
    chroot /mnt xbps-reconfigure -fa >/dev/null 2>&1
}

# ==========================================
# STEP 5: System Configuration
# ==========================================
configure_fstab() {
    log_step "Generating /etc/fstab..."
    cat > /mnt/etc/fstab <<EOF
UUID=$(blkid -s UUID -o value "$TARGET_ROOT")  /      ext4  defaults  0  1
EOF
    if [[ "$BOOT_MODE" == "efi" ]]; then
        echo "UUID=$(blkid -s UUID -o value "$TARGET_EFI")  /boot/efi  vfat  defaults  0  2" >> /mnt/etc/fstab
    fi
}

configure_system_settings() {
    log_step "Configuring hostname, timezone, locale, and keyboard..."
    
    read -p "Enter hostname (e.g., void-pc): " HOSTNAME
    echo "$HOSTNAME" > /mnt/etc/hostname
    
    echo "Common timezones: Europe/Berlin, UTC, America/New_York, Asia/Tokyo"
    read -p "Enter timezone (default: Europe/Berlin): " TZ
    TZ=${TZ:-Europe/Berlin}
    chroot /mnt ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
    
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
    if [[ "$LIBC" == "glibc" ]]; then
        echo "en_US.UTF-8 UTF-8" > /mnt/etc/default/libc-locales
        chroot /mnt xbps-reconfigure -f glibc-locales > /dev/null
    fi
    
    # FIX: The correct kbd package name for German without dead keys is de-latin1-nodeadkeys
    log_info "Setting TTY keyboard layout to German (no dead keys)..."
    sed -i 's/^#KEYMAP=.*/KEYMAP=de-latin1-nodeadkeys/' /mnt/etc/rc.conf
    if ! grep -q "^KEYMAP=" /mnt/etc/rc.conf; then
        echo "KEYMAP=de-latin1-nodeadkeys" >> /mnt/etc/rc.conf
    fi
}

configure_users() {
    log_step "Setting root password..."
    while true; do
        read -s -p "Enter new ROOT password: " ROOT_PASS; echo
        read -s -p "Confirm ROOT password: " ROOT_PASS2; echo
        [[ "$ROOT_PASS" == "$ROOT_PASS2" && -n "$ROOT_PASS" ]] && break
        log_warn "Passwords do not match or are empty. Try again."
    done
    
    log_step "Creating standard user..."
    read -p "Enter username (default: void): " USERNAME
    USERNAME=${USERNAME:-void}
    
    while true; do
        read -s -p "Enter password for $USERNAME: " USER_PASS; echo
        read -s -p "Confirm password for $USERNAME: " USER_PASS2; echo
        [[ "$USER_PASS" == "$USER_PASS2" && -n "$USER_PASS" ]] && break
        log_warn "Passwords do not match or are empty. Try again."
    done
    
    echo "root:$ROOT_PASS" | chroot /mnt chpasswd -c SHA512
    chroot /mnt useradd -m -G wheel,audio,video,storage,network -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USER_PASS" | chroot /mnt chpasswd -c SHA512
    
    # FIX: Uncomment the wheel group in /etc/sudoers so the user can actually use sudo
    log_info "Enabling sudo access for the 'wheel' group..."
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
    sed -i 's/^# %#wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
}

enable_services() {
    log_step "Enabling essential services..."
    chroot /mnt ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
}

# ==========================================
# STEP 6: Bootloader Installation
# ==========================================
install_bootloader() {
    log_step "Installing bootloader (GRUB)..."
    if [[ "$BOOT_MODE" == "efi" ]]; then
        mkdir -p /mnt/sys/firmware/efi/efivars
        mount -t efivarfs none /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    fi

    if [[ "$BOOT_MODE" == "efi" ]]; then
        case "$VOID_ARCH" in
            x86_64)  GRUB_EFI_PKG="grub-x86_64-efi"; GRUB_TARGET="x86_64-efi" ;;
            i686)    GRUB_EFI_PKG="grub-i386-efi";    GRUB_TARGET="i386-efi" ;;
            aarch64) GRUB_EFI_PKG="grub-arm64-efi";   GRUB_TARGET="arm64-efi" ;;
        esac
        chroot /mnt xbps-install -S -y "$GRUB_EFI_PKG"
        if ! chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --recheck; then
            chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --no-nvram --recheck
            chroot /mnt mkdir -p /boot/efi/EFI/boot
            case "$VOID_ARCH" in
                x86_64)  chroot /mnt cp /boot/efi/EFI/Void/grubx64.efi /boot/efi/EFI/boot/bootx64.efi ;;
                i686)    chroot /mnt cp /boot/efi/EFI/Void/grubia32.efi /boot/efi/EFI/boot/bootia32.efi ;;
                aarch64) chroot /mnt cp /boot/efi/EFI/Void/grubaa64.efi /boot/efi/EFI/boot/bootaa64.efi ;;
            esac
        fi
    else
        chroot /mnt xbps-install -S -y grub
        chroot /mnt grub-install --target=i386-pc "$TARGET_DISK"
    fi
    chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

# ==========================================
# STEP 7: Finalize, Cleanup & Reboot
# ==========================================
finalize_and_cleanup() {
    chroot /mnt xbps-reconfigure -fa > /dev/null
    umount -l /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    umount -l /mnt/run /mnt/sys /mnt/proc /mnt/dev 2>/dev/null || true
    if [[ "$BOOT_MODE" == "efi" ]]; then umount -l /mnt/boot/efi 2>/dev/null || true; fi
    umount -l /mnt 2>/dev/null || true

    echo ""
    echo "========================================="
    echo -e "${GREEN}  VOID LINUX INSTALLATION COMPLETE!${NC}"
    echo "========================================="
    read -p "Reboot now? [Y/n]: " REBOOT_CHOICE
    REBOOT_CHOICE=${REBOOT_CHOICE:-Y}
    if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then reboot; fi
}

# ==========================================
# Main Execution Flow
# ==========================================
main() {
    echo "========================================="
    echo "  Void Linux Guided Installer            "
    echo "========================================="
    
    check_root; detect_boot_mode; detect_arch; check_internet
    select_target_disk; confirm_wipe; partition_disk
    format_filesystems; mount_filesystems; mount_virtual_filesystems
    select_libc; install_base_system
    prepare_chroot
    configure_fstab; configure_system_settings; configure_users; enable_services
    install_bootloader
    finalize_and_cleanup
}

main "$@"

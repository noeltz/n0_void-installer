#!/bin/bash
# void-installer.sh - Complete Installer (Steps 1-7)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ==========================================
# STEP 1: Pre-flight Checks
# ==========================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This installer must be run as root."
        exit 1
    fi
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="efi"
    else
        BOOT_MODE="bios"
    fi
    log_info "Detected boot mode: ${BOOT_MODE^^}"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) VOID_ARCH="x86_64" ;;
        aarch64) VOID_ARCH="aarch64" ;;
        *) VOID_ARCH="$ARCH" ;;
    esac
    log_info "Detected architecture: $VOID_ARCH"
}

check_internet() {
    if ping -c 1 -W 3 1.1.1.1 &> /dev/null || ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        INTERNET_OK=true
    else
        log_warn "No internet connection detected."
        INTERNET_OK=false
    fi
}

# ==========================================
# STEP 2: Disk Selection & Partitioning
# ==========================================
select_target_disk() {
    log_step "Detecting available physical disks..."
    echo "---------------------------------------------------"

    declare -a DISK_NAMES
    local i=1

    while read -r name size model; do
        DISK_NAMES+=("$name")
        printf "  %d) %-10s %-8s %s\n" "$i" "$name" "$size" "$model"
        ((i++))
    done < <(lsblk -d -n -o NAME,SIZE,MODEL | grep -E '^(sd|nvme|vd|hd|mmcblk)')

    echo "---------------------------------------------------"

    if [[ ${#DISK_NAMES[@]} -eq 0 ]]; then
        log_error "No physical disks found!"
        exit 1
    fi

    local max_choice=$i
    echo "  $max_choice) Cancel"
    echo ""

    while true; do
        read -p "Select target disk [1-$max_choice]: " choice

        if [[ "$choice" == "$max_choice" ]]; then
            log_error "Installation cancelled by user."
            exit 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < max_choice )); then
            TARGET_DISK_NAME="${DISK_NAMES[$((choice-1))]}"
            TARGET_DISK="/dev/$TARGET_DISK_NAME"
            log_info "Selected disk: $TARGET_DISK"
            break
        else
            log_warn "Invalid selection. Please enter a number between 1 and $max_choice."
        fi
    done
}

confirm_wipe() {
    echo ""
    echo -e "${RED}===================================================${NC}"
    echo -e "${RED}  WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!${NC}"
    echo -e "${RED}===================================================${NC}"
    read -p "Type 'WIPE' (all caps) to confirm: " CONFIRM
    if [[ "$CONFIRM" != "WIPE" ]]; then
        log_error "Confirmation failed. Exiting."
        exit 1
    fi
}

partition_disk() {
    log_step "Wiping existing signatures on $TARGET_DISK..."
    wipefs -a "$TARGET_DISK" > /dev/null

    if [[ "$TARGET_DISK" == *"nvme"* ]] || [[ "$TARGET_DISK" == *"mmcblk"* ]] || [[ "$TARGET_DISK" == *"loop"* ]]; then
        PART_PREFIX="p"
    else
        PART_PREFIX=""
    fi

    if [[ "$BOOT_MODE" == "efi" ]]; then
        log_step "Creating GPT partition table for EFI..."
        sfdisk --wipe=always "$TARGET_DISK" <<EOF
label: gpt
size=512M, type=uefi
type=linux
EOF

        TARGET_EFI="${TARGET_DISK}${PART_PREFIX}1"
        TARGET_ROOT="${TARGET_DISK}${PART_PREFIX}2"
        log_info "Created EFI System Partition: $TARGET_EFI"
        log_info "Created Root Partition: $TARGET_ROOT"
    else
        log_step "Creating MBR partition table for BIOS..."
        sfdisk --wipe=always "$TARGET_DISK" <<EOF
label: dos
type=83, bootable
EOF

        TARGET_ROOT="${TARGET_DISK}${PART_PREFIX}1"
        log_info "Created Bootable Root Partition: $TARGET_ROOT"
    fi

    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
}

# ==========================================
# STEP 3: Formatting & Mounting
# ==========================================
format_filesystems() {
    log_step "Formatting filesystems..."

    if [[ "$BOOT_MODE" == "efi" ]]; then
        log_info "Formatting EFI partition ($TARGET_EFI) as FAT32..."
        mkfs.vfat -F 32 "$TARGET_EFI" > /dev/null
    fi

    log_info "Formatting Root partition ($TARGET_ROOT) as ext4..."
    mkfs.ext4 -F "$TARGET_ROOT" > /dev/null
}

mount_filesystems() {
    log_step "Mounting target filesystems to /mnt..."

    mkdir -p /mnt
    mount "$TARGET_ROOT" /mnt

    if [[ "$BOOT_MODE" == "efi" ]]; then
        mkdir -p /mnt/boot/efi
        mount "$TARGET_EFI" /mnt/boot/efi
    fi
}

mount_virtual_filesystems() {
    log_step "Mounting virtual filesystems for chroot..."

    mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run

    mount --rbind /dev /mnt/dev
    mount --make-rslave /mnt/dev
    mount -t proc /proc /mnt/proc
    mount --rbind /sys /mnt/sys
    mount --make-rslave /mnt/sys
    mount --rbind /run /mnt/run
    mount --make-rslave /mnt/run
}

# ==========================================
# STEP 4: Base System Installation
# ==========================================
select_libc() {
    log_step "Select C library (libc)..."
    echo "  1) glibc (Recommended)"
    echo "  2) musl  (Lightweight)"
    while true; do
        read -p "Enter choice [1-2] (default: 1): " choice
        choice=${choice:-1}
        case $choice in
            1) LIBC="glibc"; VOID_ARCH_SUFFIX=""; break ;;
            2) LIBC="musl"; VOID_ARCH_SUFFIX="-musl"; break ;;
            *) log_warn "Invalid choice." ;;
        esac
    done
    FULL_ARCH="${VOID_ARCH}${VOID_ARCH_SUFFIX}"
    REPO="https://repo-default.voidlinux.org/current"
    log_info "Selected: $LIBC (Architecture: $FULL_ARCH)"
}

install_base_system() {
    log_step "Copying XBPS repository keys to target..."
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

    log_step "Installing base-system & linux kernel..."
    if ! XBPS_ARCH="$FULL_ARCH" xbps-install -S -y -r /mnt -R "$REPO" base-system linux; then
        log_error "Failed to install base system."
        exit 1
    fi
    log_info "Base system installed successfully!"
}

# ==========================================
# STEP 5: System Configuration
# ==========================================
configure_fstab() {
    log_step "Generating /etc/fstab..."
    cat > /mnt/etc/fstab <<EOF
# /etc/fstab: static file system information.
UUID=$(blkid -s UUID -o value "$TARGET_ROOT")  /      ext4  defaults  0  1
EOF
    if [[ "$BOOT_MODE" == "efi" ]]; then
        echo "UUID=$(blkid -s UUID -o value "$TARGET_EFI")  /boot/efi  vfat  defaults  0  2" >> /mnt/etc/fstab
    fi
    log_info "fstab generated."
}

configure_system_settings() {
    log_step "Configuring hostname, timezone, locale, and keyboard..."

    # Hostname
    read -p "Enter hostname (e.g., void-pc): " HOSTNAME
    echo "$HOSTNAME" > /mnt/etc/hostname

    # Timezone (Default: Europe/Berlin)
    echo "Common timezones: Europe/Berlin, UTC, America/New_York, Asia/Tokyo"
    read -p "Enter timezone (default: Europe/Berlin): " TZ
    TZ=${TZ:-Europe/Berlin}
    chroot /mnt ln -sf /usr/share/zoneinfo/$TZ /etc/localtime

    # Locale (System Language: American English)
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

    if [[ "$LIBC" == "glibc" ]]; then
        echo "en_US.UTF-8 UTF-8" > /mnt/etc/default/libc-locales
        chroot /mnt xbps-reconfigure -f glibc-locales > /dev/null
    fi

    # Keyboard Layout (TTY: German - no dead keys)
    echo 'KEYMAP="de-nodeadkeys"' >> /mnt/etc/rc.conf

    log_info "System settings configured."
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

    chroot /mnt /bin/bash -c "
        echo 'root:$ROOT_PASS' | chpasswd
        useradd -m -G wheel,audio,video,storage,network -s /bin/bash $USERNAME
        echo '$USERNAME:$USER_PASS' | chpasswd
    "
    log_info "Users configured."
}

enable_services() {
    log_step "Enabling essential services..."
    chroot /mnt ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
    log_info "dhcpcd network service enabled."
}

# ==========================================
# STEP 6: Bootloader Installation
# ==========================================
install_bootloader() {
    log_step "Installing bootloader (GRUB)..."

    # Mount efivarfs for UEFI systems (required to write boot entries)
    if [[ "$BOOT_MODE" == "efi" ]]; then
        mkdir -p /mnt/sys/firmware/efi/efivars
        mount -t efivarfs none /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    fi

    if [[ "$BOOT_MODE" == "efi" ]]; then
        # Determine the correct GRUB EFI target based on architecture
        case "$VOID_ARCH" in
            x86_64)  GRUB_EFI_PKG="grub-x86_64-efi"; GRUB_TARGET="x86_64-efi" ;;
            i686)    GRUB_EFI_PKG="grub-i386-efi";    GRUB_TARGET="i386-efi" ;;
            aarch64) GRUB_EFI_PKG="grub-arm64-efi";   GRUB_TARGET="arm64-efi" ;;
            *)       log_error "Unsupported architecture for EFI: $VOID_ARCH"; exit 1 ;;
        esac

        log_info "Installing $GRUB_EFI_PKG..."
        chroot /mnt xbps-install -S -y "$GRUB_EFI_PKG"

        log_info "Running grub-install for EFI..."
        if ! chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --recheck; then
            log_warn "Standard EFI install failed. Trying with --no-nvram..."
            chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --no-nvram --recheck

            # Fallback: copy to removable/boot fallback path
            log_info "Installing fallback bootloader to /boot/efi/EFI/boot/..."
            chroot /mnt mkdir -p /boot/efi/EFI/boot
            case "$VOID_ARCH" in
                x86_64)  chroot /mnt cp /boot/efi/EFI/Void/grubx64.efi /boot/efi/EFI/boot/bootx64.efi ;;
                i686)    chroot /mnt cp /boot/efi/EFI/Void/grubia32.efi /boot/efi/EFI/boot/bootia32.efi ;;
                aarch64) chroot /mnt cp /boot/efi/EFI/Void/grubaa64.efi /boot/efi/EFI/boot/bootaa64.efi ;;
            esac
        fi
    else
        # BIOS installation
        log_info "Installing grub for BIOS..."
        chroot /mnt xbps-install -S -y grub

        log_info "Running grub-install for BIOS on $TARGET_DISK..."
        chroot /mnt grub-install --target=i386-pc "$TARGET_DISK"
    fi

    # Generate GRUB configuration
    log_info "Generating GRUB configuration..."
    chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    log_info "Bootloader installed and configured!"
}

# ==========================================
# STEP 7: Finalize, Cleanup & Reboot
# ==========================================
finalize_and_cleanup() {
    log_step "Finalizing installation (configuring all packages & generating initramfs)..."
    chroot /mnt xbps-reconfigure -fa > /dev/null
    log_info "All packages configured. Initramfs generated."

    log_step "Cleaning up - unmounting filesystems..."

    # Unmount in reverse order
    umount -l /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    umount -l /mnt/run 2>/dev/null || true
    umount -l /mnt/sys 2>/dev/null || true
    umount -l /mnt/proc 2>/dev/null || true
    umount -l /mnt/dev 2>/dev/null || true

    if [[ "$BOOT_MODE" == "efi" ]]; then
        umount -l /mnt/boot/efi 2>/dev/null || true
    fi

    umount -l /mnt 2>/dev/null || true

    echo ""
    echo "========================================="
    echo -e "${GREEN}  VOID LINUX INSTALLATION COMPLETE!${NC}"
    echo "========================================="
    echo ""
    echo "  You can now reboot and remove the live USB."
    echo ""

    read -p "Reboot now? [Y/n]: " REBOOT_CHOICE
    REBOOT_CHOICE=${REBOOT_CHOICE:-Y}
    if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
        log_info "Rebooting..."
        reboot
    else
        log_info "Reboot manually when ready: 'reboot'"
    fi
}

# ==========================================
# Main Execution Flow
# ==========================================
main() {
    echo "========================================="
    echo "  Void Linux Guided Installer            "
    echo "========================================="

    # Step 1
    log_step "Running Pre-flight Checks..."
    check_root
    detect_boot_mode
    detect_arch
    check_internet

    # Step 2
    echo ""
    log_step "Starting Disk Selection..."
    select_target_disk
    confirm_wipe
    partition_disk

    # Step 3
    echo ""
    log_step "Formatting & Mounting..."
    format_filesystems
    mount_filesystems
    mount_virtual_filesystems

    # Step 4
    echo ""
    log_step "Installing Base System..."
    select_libc
    install_base_system

    # Step 5
    echo ""
    log_step "Configuring System..."
    configure_fstab
    configure_system_settings
    configure_users
    enable_services

    # Step 6
    echo ""
    log_step "Installing Bootloader..."
    install_bootloader

    # Step 7
    echo ""
    finalize_and_cleanup
}

main "$@"

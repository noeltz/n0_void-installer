#!/bin/bash
# void-installer.sh - Step 4: Base System Installation

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
    else
        log_step "Creating MBR partition table for BIOS..."
        sfdisk --wipe=always "$TARGET_DISK" <<EOF
label: dos
type=83, bootable
EOF
        
        TARGET_ROOT="${TARGET_DISK}${PART_PREFIX}1"
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
        mkfs.vfat -F 32 "$TARGET_EFI" > /dev/null
    fi
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
    echo "  1) glibc (Recommended - Best compatibility with proprietary software & games)"
    echo "  2) musl  (Lightweight - Strict standards, some software may not work)"
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
    
    log_step "Syncing package databases and installing base-system & linux kernel..."
    log_info "This will download and install the core system. It may take a few minutes."
    
    # -S: sync repo index
    # -y: assume yes to all prompts
    # -r /mnt: target root directory
    # -R: repository URL
    if ! XBPS_ARCH="$FULL_ARCH" xbps-install -S -y -r /mnt -R "$REPO" base-system linux; then
        log_error "Failed to install base system. Check your internet connection and try again."
        exit 1
    fi
    
    log_info "Base system and kernel installed successfully!"
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
    log_step "Starting Filesystem Formatting & Mounting..."
    format_filesystems
    mount_filesystems
    mount_virtual_filesystems
    
    # Step 4
    echo ""
    log_step "Starting Base System Installation..."
    select_libc
    install_base_system
    
    echo ""
    echo "========================================="
    log_info "Step 4 Completed Successfully!"
    echo "========================================="
}

main "$@"

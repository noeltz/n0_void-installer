#!/bin/bash
# void-installer.sh - Step 2: Disk Selection & Partitioning (Fixed)

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
    
    # Arrays to hold disk data
    declare -a DISK_NAMES
    local i=1
    
    # Read lsblk output safely (handles spaces in model names)
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

    # Determine partition naming prefix (e.g., sda1 vs nvme0n1p1)
    if [[ "$TARGET_DISK" == *"nvme"* ]] || [[ "$TARGET_DISK" == *"mmcblk"* ]] || [[ "$TARGET_DISK" == *"loop"* ]]; then
        PART_PREFIX="p"
    else
        PART_PREFIX=""
    fi

    if [[ "$BOOT_MODE" == "efi" ]]; then
        log_step "Creating GPT partition table for EFI..."
        # Using sfdisk which is included in util-linux (available on Void Live ISO)
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

    # Update kernel partition table
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2 # Give the kernel a second to register the new partitions
    
    log_info "Partitioning successful! Current layout:"
    lsblk "$TARGET_DISK"
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
    
    echo ""
    echo "========================================="
    log_info "Step 2 Completed Successfully!"
    echo "========================================="
}

main "$@"

#!/bin/bash
# void-installer.sh - Complete Guided Void Linux Installer with Config Support

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
# CONFIGURATION LOADING
# ==========================================
CONFIG_FILE="${1:-void-installer.conf}"

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from: $CONFIG_FILE"
        source "$CONFIG_FILE"
        CONFIG_LOADED=true
    else
        log_warn "Config file not found: $CONFIG_FILE"
        log_info "Running in interactive mode"
        CONFIG_LOADED=false
    fi
}

# Helper function to get config value or prompt
get_config_or_prompt() {
    local var_name=$1
    local prompt_msg=$2
    local default_val=$3
    
    # Check if variable is set and non-empty in config
    if [[ -n "${!var_name}" ]]; then
        log_info "Using configured value for $var_name: ${!var_name}"
        return 0
    fi
    
    # Interactive prompt
    if [[ -n "$default_val" ]]; then
        read -p "$prompt_msg (default: $default_val): " input
        input=${input:-$default_val}
    else
        read -p "$prompt_msg: " input
    fi
    
    eval "$var_name='$input'"
}

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
        i686)    VOID_ARCH="i686" ;;
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
    # If TARGET_DISK is already set from config, skip selection
    if [[ -n "$TARGET_DISK" ]]; then
        log_info "Using pre-configured target disk: $TARGET_DISK"
        return 0
    fi
    
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
    # If TARGET_DISK was pre-configured, skip confirmation
    if [[ "$CONFIG_LOADED" == "true" && -n "${TARGET_DISK}" ]]; then
        log_info "Skipping WIPE confirmation (disk pre-configured)"
        return 0
    fi
    
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
    
    log_info "Formatting Root partition ($TARGET_ROOT) as ${ROOT_FS:-ext4}..."
    case "${ROOT_FS:-ext4}" in
        ext4) mkfs.ext4 -F "$TARGET_ROOT" > /dev/null ;;
        btrfs) mkfs.btrfs -f "$TARGET_ROOT" > /dev/null ;;
        xfs) mkfs.xfs -f "$TARGET_ROOT" > /dev/null ;;
        *) log_error "Unsupported filesystem: $ROOT_FS"; exit 1 ;;
    esac
}

mount_filesystems() {
    log_step "Mounting target filesystems to /mnt..."
    
    mkdir -p /mnt
    mount "$TARGET_ROOT" /mnt
    log_info "Mounted $TARGET_ROOT to /mnt"
    
    if [[ "$BOOT_MODE" == "efi" ]]; then
        mkdir -p /mnt/boot/efi
        mount "$TARGET_EFI" /mnt/boot/efi
        log_info "Mounted $TARGET_EFI to /mnt/boot/efi"
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
    # If LIBC is already set from config, skip selection
    if [[ -n "$LIBC" ]]; then
        log_info "Using pre-configured C library: $LIBC"
    else
        log_step "Select C library (libc)..."
        echo "  1) glibc (Recommended - Best compatibility with proprietary software & games)"
        echo "  2) musl  (Lightweight - Strict standards, some software may not work)"
        while true; do
            read -p "Enter choice [1-2] (default: 1): " choice
            choice=${choice:-1}
            case $choice in
                1) LIBC="glibc"; break ;;
                2) LIBC="musl"; break ;;
                *) log_warn "Invalid choice." ;;
            esac
        done
    fi
    
    case $LIBC in
        glibc) VOID_ARCH_SUFFIX="" ;;
        musl) VOID_ARCH_SUFFIX="-musl" ;;
        *) log_error "Invalid LIBC choice: $LIBC"; exit 1 ;;
    esac
    
    FULL_ARCH="${VOID_ARCH}${VOID_ARCH_SUFFIX}"
    REPO="${REPO_URL:-https://repo-default.voidlinux.org/current}"
    log_info "Selected: $LIBC (Architecture: $FULL_ARCH)"
}

install_base_system() {
    log_step "Copying XBPS repository keys to target..."
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
    
    log_step "Syncing package databases and installing base-system, linux kernel, and kbd..."
    log_info "This will download and install the core system. It may take a few minutes."
    
    if ! XBPS_ARCH="$FULL_ARCH" xbps-install -S -y -r /mnt -R "$REPO" base-system linux kbd; then
        log_error "Failed to install base system. Check your internet connection and try again."
        exit 1
    fi
    
    log_info "Base system, kernel, and kbd unpacked successfully!"
}

# ==========================================
# CRITICAL: Prepare Chroot & Initialize System
# ==========================================
prepare_chroot() {
    log_step "Configuring DNS for chroot environment..."
    cp -L /etc/resolv.conf /mnt/etc/resolv.conf
    
    log_step "Initializing base system configuration (creating /etc/shadow, etc.)..."
    xbps-reconfigure -r /mnt -f base-files >/dev/null 2>&1
    
    log_step "Configuring all base packages inside chroot..."
    chroot /mnt xbps-reconfigure -fa >/dev/null 2>&1
    log_info "Chroot prepared and base packages configured."
}

# ==========================================
# STEP 5: System Configuration
# ==========================================
configure_fstab() {
    log_step "Generating /etc/fstab..."
    cat > /mnt/etc/fstab <<EOF
# /etc/fstab: static file system information.
UUID=$(blkid -s UUID -o value "$TARGET_ROOT")  /      ${ROOT_FS:-ext4}  defaults  0  1
EOF
    if [[ "$BOOT_MODE" == "efi" ]]; then
        echo "UUID=$(blkid -s UUID -o value "$TARGET_EFI")  /boot/efi  vfat  defaults  0  2" >> /mnt/etc/fstab
    fi
    log_info "fstab generated."
}

configure_system_settings() {
    log_step "Configuring hostname, timezone, locale, and keyboard..."
    
    # Hostname
    get_config_or_prompt HOSTNAME "Enter hostname (e.g., void-pc)" ""
    echo "$HOSTNAME" > /mnt/etc/hostname
    
    # Timezone
    get_config_or_prompt TIMEZONE "Enter timezone" "Europe/Berlin"
    chroot /mnt ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    
    # Locale
    get_config_or_prompt LOCALE "Enter system locale" "en_US.UTF-8"
    log_info "Setting system language to $LOCALE..."
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf
    
    if [[ "$LIBC" == "glibc" ]]; then
        echo "$LOCALE UTF-8" > /mnt/etc/default/libc-locales
        chroot /mnt xbps-reconfigure -f glibc-locales > /dev/null
    fi
    
    # Keyboard Layout
    get_config_or_prompt KEYBOARD_LAYOUT "Enter TTY keyboard layout" "de-latin1-nodeadkeys"
    log_info "Setting TTY keyboard layout to $KEYBOARD_LAYOUT..."
    grep -v '^KEYMAP=' /mnt/etc/rc.conf > /mnt/etc/rc.conf.tmp 2>/dev/null || true
    echo "KEYMAP=$KEYBOARD_LAYOUT" >> /mnt/etc/rc.conf.tmp
    mv /mnt/etc/rc.conf.tmp /mnt/etc/rc.conf
    
    log_info "System settings configured."
}

configure_users() {
    # Username from config or prompt
    get_config_or_prompt USERNAME "Enter username" "void"
    
    # Passwords are ALWAYS prompted interactively for security
    log_step "Setting root password..."
    while true; do
        read -s -p "Enter new ROOT password: " ROOT_PASS; echo
        read -s -p "Confirm ROOT password: " ROOT_PASS2; echo
        [[ "$ROOT_PASS" == "$ROOT_PASS2" && -n "$ROOT_PASS" ]] && break
        log_warn "Passwords do not match or are empty. Try again."
    done
    
    log_step "Creating standard user '$USERNAME'..."
    while true; do
        read -s -p "Enter password for $USERNAME: " USER_PASS; echo
        read -s -p "Confirm password for $USERNAME: " USER_PASS2; echo
        [[ "$USER_PASS" == "$USER_PASS2" && -n "$USER_PASS" ]] && break
        log_warn "Passwords do not match or are empty. Try again."
    done
    
    log_info "Setting root password..."
    echo "root:$ROOT_PASS" | chroot /mnt chpasswd -c SHA512
    
    log_info "Creating user '$USERNAME'..."
    chroot /mnt useradd -m -G wheel,audio,video,storage,network -s /bin/bash "$USERNAME"
    
    log_info "Setting user password..."
    echo "$USERNAME:$USER_PASS" | chroot /mnt chpasswd -c SHA512
    
    log_info "Enabling sudo access for the 'wheel' group..."
    sed -i 's/^#%#wheel ALL=(ALL) ALL/%#wheel ALL=(ALL) ALL/' /mnt/etc/sudoers
    
    log_info "Users configured. '$USERNAME' has been added to the 'wheel' group with sudo access."
}

enable_services() {
    log_step "Enabling essential services..."
    
    # If services are configured, use them; otherwise default to dhcpcd
    if [[ -n "$ENABLE_SERVICES" ]]; then
        for service in $ENABLE_SERVICES; do
            log_info "Enabling service: $service"
            chroot /mnt ln -sf /etc/sv/$service /etc/runit/runsvdir/default/
        done
    else
        log_info "Enabling default service: dhcpcd"
        chroot /mnt ln -sf /etc/sv/dhcpcd /etc/runit/runsvdir/default/
    fi
    
    log_info "Network service enabled."
}

# ==========================================
# STEP 6: Bootloader Installation
# ==========================================
install_bootloader() {
    # Check if bootloader installation should be skipped
    if [[ "${BOOTLOADER:-grub}" == "none" ]]; then
        log_info "Skipping bootloader installation (configured as 'none')"
        return 0
    fi
    
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
            *)       log_error "Unsupported architecture for EFI: $VOID_ARCH"; exit 1 ;;
        esac

        log_info "Installing $GRUB_EFI_PKG..."
        chroot /mnt xbps-install -S -y "$GRUB_EFI_PKG"

        log_info "Running grub-install for EFI..."
        if ! chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --recheck; then
            log_warn "Standard EFI install failed. Trying with --no-nvram..."
            chroot /mnt grub-install --target="$GRUB_TARGET" --efi-directory=/boot/efi --bootloader-id="Void" --no-nvram --recheck

            log_info "Installing fallback bootloader to /boot/efi/EFI/boot/..."
            chroot /mnt mkdir -p /boot/efi/EFI/boot
            case "$VOID_ARCH" in
                x86_64)  chroot /mnt cp /boot/efi/EFI/Void/grubx64.efi /boot/efi/EFI/boot/bootx64.efi ;;
                i686)    chroot /mnt cp /boot/efi/EFI/Void/grubia32.efi /boot/efi/EFI/boot/bootia32.efi ;;
                aarch64) chroot /mnt cp /boot/efi/EFI/Void/grubaa64.efi /boot/efi/EFI/boot/bootaa64.efi ;;
            esac
        fi
    else
        log_info "Installing grub for BIOS..."
        chroot /mnt xbps-install -S -y grub

        log_info "Running grub-install for BIOS on $TARGET_DISK..."
        chroot /mnt grub-install --target=i386-pc "$TARGET_DISK"
    fi

    log_info "Generating GRUB configuration..."
    chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    log_info "Bootloader installed and configured!"
}

# ==========================================
# STEP 7: Finalize, Cleanup & Reboot
# ==========================================
finalize_and_cleanup() {
    log_step "Finalizing installation (regenerating initramfs with all configs)..."
    chroot /mnt xbps-reconfigure -fa > /dev/null
    log_info "All packages configured. Initramfs generated."

    log_step "Cleaning up - unmounting filesystems..."

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

    # Check if auto-reboot is configured
    if [[ "${AUTO_REBOOT}" == "true" ]]; then
        log_info "Auto-reboot enabled. Rebooting now..."
        reboot
    else
        read -p "Reboot now? [Y/n]: " REBOOT_CHOICE
        REBOOT_CHOICE=${REBOOT_CHOICE:-Y}
        if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
            log_info "Rebooting..."
            reboot
        else
            log_info "Reboot manually when ready: 'reboot'"
        fi
    fi
}

# ==========================================
# Main Execution Flow
# ==========================================
main() {
    echo "========================================="
    echo "  Void Linux Guided Installer            "
    echo "========================================="
    
    # Load configuration
    load_config
    
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
    
    # Critical Chroot Prep
    echo ""
    prepare_chroot
    
    # Step 5
    echo ""
    log_step "Starting System Configuration..."
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

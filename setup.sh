#!/bin/bash
# void-installer.sh - Step 1: Pre-flight Checks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 1. Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This installer must be run as root. Please use 'sudo ./void-installer.sh' or switch to root."
        exit 1
    fi
    log_info "Root privileges confirmed."
}

# 2. Detect Boot Mode (EFI vs BIOS)
detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="efi"
    else
        BOOT_MODE="bios"
    fi
    log_info "Detected boot mode: ${BOOT_MODE^^}"
}

# 3. Detect Architecture
detect_arch() {
    ARCH=$(uname -m)
    # Map uname -m to Void architecture names
    case "$ARCH" in
        x86_64) VOID_ARCH="x86_64" ;;
        aarch64) VOID_ARCH="aarch64" ;;
        armv7l) VOID_ARCH="armv7l" ;;
        i686) VOID_ARCH="i686" ;;
        *) VOID_ARCH="$ARCH" ;;
    esac
    log_info "Detected architecture: $VOID_ARCH"
}

# 4. Check Internet Connectivity
check_internet() {
    log_info "Checking internet connectivity..."
    # Ping a reliable public DNS server
    if ping -c 1 -W 3 1.1.1.1 &> /dev/null || ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        log_info "Internet connection is active."
        INTERNET_OK=true
    else
        log_warn "No internet connection detected. Network installation will not be possible."
        INTERNET_OK=false
    fi
}

# Main execution for Step 1
main() {
    echo "========================================="
    echo "  Void Linux Guided Installer - Step 1   "
    echo "  Pre-flight Checks                      "
    echo "========================================="
    
    check_root
    detect_boot_mode
    detect_arch
    check_internet
    
    echo "========================================="
    log_info "Pre-flight checks completed successfully."
    echo "========================================="
}

main "$@"

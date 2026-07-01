#!/bin/bash
# hardware.sh - host-side hardware detection
# Writes ./hardware-packages.txt and ./hardware-services.txt,
# which are consumed inside the chroot (alongside packages.txt).

# Detects GPU/CPU/VM/laptop/wifi/printer/fingerprint on the live host
# and lets the user pick the non-deterministic bits (NVIDIA family,
# Broadcom wl, printer brand, fingerprint) via fzf.
detectHardware() (
    set +e

    separator -i
    figlet "HARDWARE DETECTION"
    separator -i
    sleep 1

    HW_PKGS=()
    HW_SERVICES=()

    # --- CPU microcode ---
    CPU_VENDOR=$(awk -F: '/^vendor_id/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
    case "$CPU_VENDOR" in
        GenuineIntel)
            HW_PKGS+=("intel-ucode")
            echo "  CPU: Intel -> intel-ucode"
            ;;
        AuthenticAMD)
            echo "  CPU: AMD (microcode ships in linux-firmware-amd, nothing extra)"
            ;;
        *)
            echo "  CPU: unknown ($CPU_VENDOR), skipping microcode"
            ;;
    esac

    # --- GPU(s) via /sys/bus/pci (class 0x03xx = display) ---
    has_intel=0; has_amd=0; has_nvidia=0
    for d in /sys/bus/pci/devices/*; do
        [ -e "$d" ] || continue
        cl=$(cat "$d/class" 2>/dev/null) || continue
        case "$cl" in
            0x03*)
                v=$(cat "$d/vendor" 2>/dev/null) || continue
                case "$v" in
                    0x8086) has_intel=1 ;;
                    0x1002) has_amd=1 ;;
                    0x10de) has_nvidia=1 ;;
                esac
                ;;
        esac
    done

    if [ "$has_nvidia" = "1" ]; then
        # Proprietary nvidia builds a kernel module via DKMS
        HW_PKGS+=("dkms" "linux-headers" "base-devel")
        _nvidiaChoose
        HW_PKGS+=("mesa-dri" "vulkan-loader" "$NVIDIA_PKG")
        case "$NVIDIA_PKG" in
            nouveau) HW_PKGS+=("mesa-vulkan-nouveau" "mesa-dri-32bit") ;;
            nvidia)  HW_PKGS+=("nvidia-libs-32bit") ;;
            *)       HW_PKGS+=("${NVIDIA_PKG}-libs-32bit") ;;
        esac
        if [ "$has_intel" = "1" ]; then
            HW_PKGS+=("mesa-vulkan-intel" "intel-video-accel" "libvdpau-va-gl")
            echo "  GPU: NVIDIA + Intel -> Optimus (PRIME render offload via prime-run)"
        else
            echo "  GPU: NVIDIA -> $NVIDIA_PKG"
        fi
    elif [ "$has_intel" = "1" ]; then
        HW_PKGS+=("mesa-dri" "vulkan-loader" "mesa-vulkan-intel" "intel-video-accel" "libvdpau-va-gl")
        echo "  GPU: Intel"
    elif [ "$has_amd" = "1" ]; then
        HW_PKGS+=("mesa-dri" "vulkan-loader" "mesa-vulkan-radeon" "mesa-vaapi" "libvdpau-va-gl")
        echo "  GPU: AMD"
    else
        HW_PKGS+=("mesa-dri")
        echo "  GPU: none detected -> mesa-dri fallback"
    fi

    # --- VM guest additions ---
    _detectVM

    # --- Laptop -> tlp (skip acpid: it conflicts with elogind already installed) ---
    _detectLaptop

    # --- Broadcom Wi-Fi (needs proprietary wl on some BCM43xx) ---
    _detectBroadcomWifi

    # --- Printer brand (cannot be auto-detected at install time) ---
    # _printerChoose

    # --- Fingerprint reader ---
    _detectFingerprint

    separator -i
    echo "Hardware packages:"
    printf '  %s\n' "${HW_PKGS[@]}"
    if [ "${#HW_SERVICES[@]}" -gt 0 ]; then
        echo "Hardware services:"
        printf '  %s\n' "${HW_SERVICES[@]}"
    fi
    separator -i
    sleep 1

    printf '%s\n' "${HW_PKGS[@]}" > ./hardware-packages.txt
    printf '%s\n' "${HW_SERVICES[@]}" > ./hardware-services.txt
)

_nvidiaChoose() {
    separator -iwi
    echo "NVIDIA GPU detected. PCI device(s):"
    for d in /sys/bus/pci/devices/*; do
        [ -e "$d" ] || continue
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
        case "$(cat "$d/class" 2>/dev/null)" in 0x03*) echo "  vendor:device 10de:$(cat "$d/device" 2>/dev/null)" ;; esac
    done
    separator -i
    echo "Pick the driver for your GPU generation (Turing+ = GTX 16xx / RTX 20xx, 2018+)."
    echo "If unsure, 'nouveau' is the safe open default; a wrong proprietary pkg won't boot."
    separator -iwi
    NVIDIA_DRV=$(printf '%s\n' \
        "nvidia - Turing+ (GTX 16xx / RTX 20xx and newer)" \
        "nvidia580 - Maxwell to Volta" \
        "nvidia470 - Kepler" \
        "nvidia390 - Fermi" \
        "nouveau - open source, safe default" | fzf)
    NVIDIA_PKG="${NVIDIA_DRV%% *}"
}

_detectVM() {
    if ! awk '/^flags/{print; exit}' /proc/cpuinfo | grep -qw hypervisor; then
        echo "  VM: none (bare metal)"
        return
    fi
    prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    sysv=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
    combo="$prod $sysv"
    echo "  VM: detected (product='$prod' vendor='$sysv')"
    case "$combo" in
        *VirtualBox*)
            HW_PKGS+=("virtualbox-ose-guest" "virtualbox-ose-guest-dkms" "dkms" "linux-headers" "base-devel")
            ;;
        *VMware*)
            HW_PKGS+=("open-vm-tools")
            ;;
        *KVM*|*QEMU*|*Bochs*)
            HW_PKGS+=("spice-vdagent")
            ;;
        *)
            echo "  VM: unrecognized platform, no guest additions"
            ;;
    esac
}

_detectLaptop() {
    ct=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)
    case "$ct" in
        8|9|10|11|14|30|31|32)
            HW_PKGS+=("tlp")
            HW_SERVICES+=("tlp")
            echo "  Chassis: portable (type=$ct) -> tlp"
            ;;
        *)
            echo "  Chassis: type=${ct:-unknown} (not portable)"
            ;;
    esac
}

_detectBroadcomWifi() {
    found=0
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] || continue
        [ "$(cat "$iface/device/vendor" 2>/dev/null)" = "0x14e4" ] && found=1
    done
    [ "$found" = "0" ] && return

    separator -iwi
    echo "Broadcom wireless NIC detected. Some BCM43xx chips need the proprietary"
    echo "'wl' driver; others work with the in-tree b43/brcmsmac + linux-firmware."
    BC_ANSWER=$(printf '%s\n' "no - try in-tree driver first" "yes - install broadcom-wl-dkms" | fzf)
    if [ "${BC_ANSWER%% *}" = "yes" ]; then
        HW_PKGS+=("broadcom-wl-dkms" "dkms" "linux-headers" "base-devel")
        echo "  Wi-Fi: Broadcom -> broadcom-wl-dkms"
    else
        echo "  Wi-Fi: Broadcom -> in-tree driver (linux-firmware)"
    fi
}

_printerChoose() {
    separator -iwi
    echo "Printer: cups + cups-filters are already in the base list."
    echo "Pick a brand driver, or 'none' for driverless / IPP Everywhere."
    PRN=$(printf '%s\n' \
        "none - driverless / IPP Everywhere" \
        "hplip - Hewlett-Packard" \
        "foomatic - Brother (foomatic-db + brother-brlaser)" \
        "epson-inkjet-printer-escpr - Epson inkjet" \
        "cnijfilter2 - Canon PIXMA/MAXIFY (nonfree)" | fzf)
    case "$PRN" in
        hplip*)    HW_PKGS+=("hplip") ;;
        foomatic*) HW_PKGS+=("foomatic-db" "foomatic-db-nonfree" "brother-brlaser") ;;
        epson*)    HW_PKGS+=("epson-inkjet-printer-escpr") ;;
        cnijfilter2) HW_PKGS+=("cnijfilter2") ;;
    esac
    echo "  Printer: ${PRN%% -*}"
}

_detectFingerprint() {
    hit=0
    for d in /sys/bus/usb/devices/*; do
        [ -r "$d/idVendor" ] || continue
        case "$(cat "$d/idVendor" 2>/dev/null)" in
            06cb|138a|27c6|1c96) hit=1 ;;
        esac
    done
    [ "$hit" = "0" ] && return

    separator -iwi
    echo "Possible fingerprint reader detected (Synaptics/Validity/Goodix/Egis)."
    echo "Stock libfprint covers many readers; newer Dell/Lenovo may need libfprint-tod."
    FP_ANSWER=$(printf '%s\n' "no" "yes - install fprintd + libfprint" | fzf)
    if [ "${FP_ANSWER%% *}" = "yes" ]; then
        HW_PKGS+=("fprintd" "libfprint")
        echo "  Fingerprint: fprintd + libfprint"
    fi
}

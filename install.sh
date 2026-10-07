#!/bin/bash
# Void Linux installer — single-file installer per installer_spec.md (v1.1).
#
# Installs a complete, bootable Void Linux (glibc, x86_64, UEFI) onto one
# whole disk: GPT + GRUB, btrfs with fixed subvolume layout, snapper
# snapshots around every xbps transaction, grub-btrfs bootable snapshots,
# NetworkManager, hardware detection, optional chezmoi dotfiles.
#
# Exit codes: 0 success, 1 unexpected error, 2 usage/config error,
# 3 preflight/probe failure (disk untouched), 4 aborted by user.

set -Eeuo pipefail

INSTALLER_VERSION="1.3.2"
BTRFS_OPTS="rw,noatime,compress=zstd:1,discard=async"
MIN_DISK_BYTES=21474836480   # 20 GiB
GRUB_BTRFS_OWN=0             # set by probe_packages when grub-btrfs-runit ships no service dir
NETWORKMANAGER_OWN=0         # set by probe_packages when NetworkManager ships no service dir
CHEZMOI_FAILED=0
CURRENT_STEP_N=0
CURRENT_STEP_NAME="startup"
VALIDATE_REASON=""
CONFIG_SET=" "               # " KEY1 KEY2 ... " — keys that came from the config file

declare -A PKG_SEEN=()
PKGS_ALL=()
SV_FATAL=()
SV_OPTIONAL=()

# --------------------------------------------------------------------------
# CLI / configuration (spec sections 5, 6)
# --------------------------------------------------------------------------

usage() {
  cat <<EOF
void-installer $INSTALLER_VERSION

Usage: install.sh [--config FILE] [--yes] [--help]

  --config FILE  read settings from FILE (default: ./install.conf if it exists)
  --yes          unattended mode: no dialogs, no confirmation; every value
                 without a default must be present in the config
  --help         print this help and exit
EOF
}

parse_args() {
  CONFIG_FILE=""
  YES_MODE=0
  while (( $# > 0 )); do
    case $1 in
      --config)
        if [[ -z ${2:-} ]]; then
          usage
          exit 2
        fi
        CONFIG_FILE=$2
        shift 2
        ;;
      --yes)
        YES_MODE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  done
  if [[ -z $CONFIG_FILE && -f ./install.conf ]]; then
    CONFIG_FILE=./install.conf
  fi
}

# The config is parsed, never sourced: sourcing would execute arbitrary code
# and expand $ inside values (destroying e.g. a '$6$...' password hash).
load_config() {
  local file=$1 line key val
  if [[ ! -f $file || ! -r $file ]]; then
    echo "Cannot read config file: $file" >&2
    exit 2
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ -z $line || $line == \#* ]]; then
      continue
    fi
    if ! [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      echo "Invalid config line: $line" >&2
      exit 2
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    case $key in
      TARGET_DISK|HOSTNAME|USERNAME|USER_PASSWORD|USER_PASSWORD_HASH|\
      ROOT_PASSWORD|ROOT_PASSWORD_HASH|USER_SHELL|\
      TIMEZONE|LOCALE|KEYMAP|MIRROR|SWAP|CHEZMOI_REPO|EXTRA_PACKAGES|HW_CHASSIS|\
      HW_TOUCH|HW_FINGERPRINT|HW_BLUETOOTH)
        ;;
      *)
        echo "Invalid config line: $line" >&2
        exit 2
        ;;
    esac
    if (( ${#val} >= 2 )) && [[ ${val:0:1} == '"' && ${val: -1} == '"' ]]; then
      val=${val:1:-1}
    elif (( ${#val} >= 2 )) && [[ ${val:0:1} == "'" && ${val: -1} == "'" ]]; then
      val=${val:1:-1}
    fi
    printf -v "$key" '%s' "$val"
    CONFIG_SET+="$key "
  done < "$file"
}

apply_defaults() {
  [[ -v HOSTNAME ]] || HOSTNAME=void
  [[ -v USER_SHELL ]] || USER_SHELL=/bin/bash
  [[ -v TIMEZONE ]] || TIMEZONE=UTC
  [[ -v LOCALE ]] || LOCALE=en_US.UTF-8
  [[ -v KEYMAP ]] || KEYMAP=us
  [[ -v MIRROR ]] || MIRROR=https://repo-default.voidlinux.org
  [[ -v SWAP ]] || SWAP=zram
  [[ -v CHEZMOI_REPO ]] || CHEZMOI_REPO=""
  [[ -v EXTRA_PACKAGES ]] || EXTRA_PACKAGES=""
  [[ -v HW_CHASSIS ]] || HW_CHASSIS=auto
  [[ -v HW_TOUCH ]] || HW_TOUCH=auto
  [[ -v HW_FINGERPRINT ]] || HW_FINGERPRINT=auto
  [[ -v HW_BLUETOOTH ]] || HW_BLUETOOTH=auto
}

is_config_set() {
  [[ $CONFIG_SET == *" $1 "* ]]
}

# --------------------------------------------------------------------------
# Validation (spec section 6)
# --------------------------------------------------------------------------

# validate_one KEY VALUE → 0 valid, 1 invalid (reason in VALIDATE_REASON).
# TARGET_DISK is validated by validate_target_disk; EXTRA_PACKAGES by the
# package probe.
validate_one() {
  local key=$1 val=$2
  local esc=$val
  VALIDATE_REASON=""
  case $key in
    HOSTNAME)
      if ! [[ $val =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        VALIDATE_REASON="must be lowercase letters, digits and hyphens (max 63 chars, no leading/trailing hyphen)"
        return 1
      fi
      ;;
    USERNAME)
      if ! [[ $val =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        VALIDATE_REASON="must match ^[a-z_][a-z0-9_-]{0,31}$"
        return 1
      fi
      if [[ $val == root ]]; then
        VALIDATE_REASON="must not be root"
        return 1
      fi
      ;;
    USER_PASSWORD)
      if [[ -z $val ]]; then
        VALIDATE_REASON="must not be empty"
        return 1
      fi
      ;;
    USER_PASSWORD_HASH)
      if ! [[ $val == \$6\$* ]]; then
        VALIDATE_REASON="must be a SHA-512 crypt hash beginning with \$6\$"
        return 1
      fi
      ;;
    ROOT_PASSWORD)
      if [[ -z $val ]]; then
        VALIDATE_REASON="must not be empty"
        return 1
      fi
      ;;
    ROOT_PASSWORD_HASH)
      if ! [[ $val == \$6\$* ]]; then
        VALIDATE_REASON="must be a SHA-512 crypt hash beginning with \$6\$"
        return 1
      fi
      ;;
    USER_SHELL)
      if [[ $val != /bin/bash ]]; then
        VALIDATE_REASON="must be /bin/bash in v1"
        return 1
      fi
      ;;
    TIMEZONE)
      if [[ ! -e /usr/share/zoneinfo/$val ]]; then
        VALIDATE_REASON="not found under /usr/share/zoneinfo"
        return 1
      fi
      ;;
    LOCALE)
      # Lines in libc-locales carry trailing whitespace (the file is generated
      # from glibc's localedata/SUPPORTED, where the continuation backslash
      # becomes a space) — the match must tolerate it.
      esc=$(locale_key "$val")
      esc=${esc//./\\.}
      if ! grep -qiE "^#?[[:space:]]*${esc}[[:space:]]+UTF-8[[:space:]]*$" /etc/default/libc-locales 2>/dev/null; then
        VALIDATE_REASON="not available in /etc/default/libc-locales (e.g. en_US.UTF-8)"
        return 1
      fi
      ;;
    KEYMAP)
      if ! loadkeys --parse "$val" >/dev/null 2>&1; then
        VALIDATE_REASON="not a valid console keymap"
        return 1
      fi
      ;;
    MIRROR)
      if ! [[ $val =~ ^https://[^/]+(/[^/]+)*$ ]] || [[ $val == */current ]]; then
        VALIDATE_REASON="needs https://host[/path], no trailing slash, no /current"
        return 1
      fi
      ;;
    SWAP)
      if [[ $val != zram && $val != none ]]; then
        VALIDATE_REASON="must be zram or none"
        return 1
      fi
      ;;
    CHEZMOI_REPO)
      if [[ -n $val ]]; then
        if ! [[ $val =~ ^https://[^[:space:]]+$ || $val =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
          VALIDATE_REASON="must be an https:// URL or a GitHub user/repo (or empty to skip)"
          return 1
        fi
      fi
      ;;
    HW_CHASSIS)
      if [[ $val != auto && $val != laptop && $val != desktop && $val != vm ]]; then
        VALIDATE_REASON="must be auto, laptop, desktop or vm"
        return 1
      fi
      ;;
    HW_TOUCH|HW_FINGERPRINT|HW_BLUETOOTH)
      if [[ $val != auto && $val != yes && $val != no ]]; then
        VALIDATE_REASON="must be auto, yes or no"
        return 1
      fi
      ;;
    TARGET_DISK|EXTRA_PACKAGES)
      ;;
  esac
  return 0
}

# Normalise a locale name for comparison: lowercase, and treat ".utf8" the
# same as ".utf-8" (glibc accepts both spellings of the UTF-8 codeset).
locale_key() {  # $1 = locale name; echoes normalised form
  local k=${1,,}
  if [[ $k == *.utf8 ]]; then
    k=${k%.utf8}.utf-8
  fi
  printf '%s' "$k"
}

# glibc locale names are case-sensitive (en_US.UTF-8). Accept user input in
# any case and rewrite it to the canonical spelling from libc-locales
# (en_us.utf8 -> en_US.UTF-8). Validation itself is validate_one's job.
canonicalize_locale() {
  local line canonical
  [[ -n ${LOCALE:-} ]] || return 0
  while IFS= read -r line; do
    line=${line%$'\r'}
    line=${line#\#}
    line=${line#"${line%%[![:space:]]*}"}   # trim whitespace after the comment marker
    canonical=${line%% *}
    [[ -n $canonical ]] || continue
    if [[ $(locale_key "$canonical") == "$(locale_key "$LOCALE")" ]]; then
      LOCALE=$canonical
      return 0
    fi
  done < /etc/default/libc-locales
  return 0
}

validate_all() {
  canonicalize_locale
  local key
  for key in HOSTNAME USER_SHELL TIMEZONE LOCALE KEYMAP MIRROR SWAP CHEZMOI_REPO \
             EXTRA_PACKAGES HW_CHASSIS HW_TOUCH HW_FINGERPRINT HW_BLUETOOTH; do
    if ! validate_one "$key" "${!key}"; then
      echo "Invalid value for $key: $VALIDATE_REASON" >&2
      exit 2
    fi
  done

  if [[ -z ${USERNAME:-} ]]; then
    echo "Missing required setting: USERNAME" >&2
    exit 2
  fi
  if ! validate_one USERNAME "$USERNAME"; then
    echo "Invalid value for USERNAME: $VALIDATE_REASON" >&2
    exit 2
  fi

  # Exactly one of USER_PASSWORD / USER_PASSWORD_HASH must be set; the hash wins.
  if [[ -v USER_PASSWORD_HASH ]]; then
    if ! validate_one USER_PASSWORD_HASH "$USER_PASSWORD_HASH"; then
      echo "Invalid value for USER_PASSWORD_HASH: $VALIDATE_REASON" >&2
      exit 2
    fi
  elif [[ -v USER_PASSWORD ]]; then
    if ! validate_one USER_PASSWORD "$USER_PASSWORD"; then
      echo "Invalid value for USER_PASSWORD: $VALIDATE_REASON" >&2
      exit 2
    fi
  else
    echo "Missing required setting: USER_PASSWORD" >&2
    exit 2
  fi

  # Root credentials are configured independently so console recovery remains
  # possible if the regular user's password or account is unavailable.
  if [[ -v ROOT_PASSWORD_HASH ]]; then
    if ! validate_one ROOT_PASSWORD_HASH "$ROOT_PASSWORD_HASH"; then
      echo "Invalid value for ROOT_PASSWORD_HASH: $VALIDATE_REASON" >&2
      exit 2
    fi
  elif [[ -v ROOT_PASSWORD ]]; then
    if ! validate_one ROOT_PASSWORD "$ROOT_PASSWORD"; then
      echo "Invalid value for ROOT_PASSWORD: $VALIDATE_REASON" >&2
      exit 2
    fi
  else
    echo "Missing required setting: ROOT_PASSWORD" >&2
    exit 2
  fi

  if [[ -z ${TARGET_DISK:-} ]]; then
    echo "Missing required setting: TARGET_DISK" >&2
    exit 2
  fi
  validate_target_disk
}

# Normalises TARGET_DISK (readlink -f) and checks eligibility rules 1-4 of
# spec 7.1. Rules 1/2/4 → exit 2 "Invalid value..."; rule 3 (mounted) has its
# own message.
validate_target_disk() {
  local dtype sizeb
  TARGET_DISK=$(readlink -f "$TARGET_DISK")
  dtype=$(lsblk -dno TYPE "$TARGET_DISK" 2>/dev/null || true)
  if [[ $dtype != disk ]]; then
    echo "Invalid value for TARGET_DISK: not a whole disk" >&2
    exit 2
  fi
  if [[ -n $(lsblk -no MOUNTPOINTS "$TARGET_DISK" 2>/dev/null) ]]; then
    echo "Target disk or one of its partitions is mounted." >&2
    exit 2
  fi
  sizeb=$(lsblk -dbno SIZE "$TARGET_DISK" 2>/dev/null || echo 0)
  if ! [[ $sizeb =~ ^[0-9]+$ ]] || (( sizeb < MIN_DISK_BYTES )); then
    echo "Invalid value for TARGET_DISK: disk smaller than 20 GiB" >&2
    exit 2
  fi
}

# --------------------------------------------------------------------------
# Preflight (spec section 4)
# --------------------------------------------------------------------------

require_tool() {  # $1 = tool; extra args = benign invocation for a run check
  local t=$1
  shift
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "Required tool not found on the live system: $t" >&2
    exit 3
  fi
  if (( $# > 0 )) && ! "$t" "$@" >/dev/null 2>&1; then
    echo "Required tool not usable on the live system: $t" >&2
    exit 3
  fi
}

preflight() {
  # Check 0 runs before any network use; it is the only check that exits 2.
  if ! [[ $MIRROR =~ ^https://[^/]+(/[^/]+)*$ ]] || [[ $MIRROR == */current ]]; then
    echo "Invalid MIRROR (needs https://host[/path], no trailing slash, no /current)." >&2
    exit 2
  fi
  if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root." >&2
    exit 3
  fi
  if ! (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    echo "Bash 4.4 or newer required." >&2
    exit 3
  fi
  if [[ $(uname -m) != x86_64 ]]; then
    echo "Only x86_64 is supported." >&2
    exit 3
  fi
  if ! ldd --version 2>&1 | grep -qi 'GNU libc'; then
    echo "musl is not supported." >&2
    exit 3
  fi
  if [[ ! -d /sys/firmware/efi ]]; then
    echo "Not booted in UEFI mode." >&2
    exit 3
  fi
  # Check 6 uses only bash /dev/tcp: the live ISO ships no curl, and its xbps
  # may be too old for the current repositories (both verified on the ISO).
  local mirror_host=${MIRROR#https://}
  if ! timeout 10 bash -c "exec 3<>/dev/tcp/${mirror_host%%/*}/443" 2>/dev/null; then
    echo "No network connection to $MIRROR. Connect first and re-run." >&2
    exit 3
  fi
  local mem_kB
  mem_kB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  if ! [[ $mem_kB =~ ^[0-9]+$ ]] || (( mem_kB < 1048576 )); then
    echo "At least 1 GiB RAM required." >&2
    exit 3
  fi

  # xbps self-update: an outdated xbps refuses all other transactions
  # ("xbps must be updated"), including the target bootstrap later.
  if ! xbps-install -Syu xbps; then
    echo "Failed to update xbps. If the mirror changed layout recently, this ISO's xbps may be too old to read it; use a newer ISO." >&2
    exit 3
  fi

  # The repositories moved to a flat layout (/current/x86_64-repodata instead
  # of /current/x86_64/x86_64-repodata) in October 2026; an xbps from before
  # that change cannot read the new layout and every package would fail with
  # "not found in repository pool". A canary query makes that fail here, with
  # an actionable message, before anything else runs.
  if ! xbps-query -R -M --repository="$MIRROR/current" base-system >/dev/null 2>&1; then
    echo "Repository $MIRROR/current is not readable by this xbps (layout mismatch or mirror problem). Use a newer live ISO or another MIRROR." >&2
    exit 3
  fi

  # Host tools are NOT installed. The ISO's base-system ships everything the
  # installer executes on the host, and its set is internally consistent.
  # Installing current repo packages onto the old ISO userland instead
  # breaks binaries with "symbol lookup error" (observed with curl), and a
  # full sync needs more space than the ISO's RAM-backed root offers.
  # Tools are verified to run, not just to exist.
  require_tool sfdisk --version
  require_tool mkfs.btrfs --version
  require_tool mkfs.vfat
  require_tool lsblk --version
  require_tool blkid --version
  require_tool wipefs --version
  require_tool udevadm --version
  require_tool loadkeys
  require_tool lspci --version
  require_tool lsusb --version
  if (( YES_MODE == 0 )); then
    if ! command -v dialog >/dev/null 2>&1; then
      # dialog is the only host tool the ISO does not ship
      if ! xbps-install -Sy dialog; then
        echo "Failed to install dialog." >&2
        exit 3
      fi
    fi
    require_tool dialog --version
  fi
}

# --------------------------------------------------------------------------
# Hardware detection (spec section 8.1)
# --------------------------------------------------------------------------

hw_gpu_add() {
  [[ $HW_GPUS == *"$1"* ]] || HW_GPUS="$HW_GPUS${HW_GPUS:+ }$1"
}

detect_hardware() {
  local ct="" cpu_vendor line vid p d
  HW_VM=no
  HW_VM_TYPE=other
  HW_CHASSIS_RESULT=desktop
  HW_CONVERTIBLE=no
  HW_CPU=unknown
  HW_GPUS=""
  HW_TOUCH_RESULT=no
  HW_FINGERPRINT_RESULT=no
  HW_BLUETOOTH_RESULT=no
  HW_WIFI=no

  if grep -qw hypervisor /proc/cpuinfo; then
    HW_VM=yes
    HW_CHASSIS_RESULT=vm
    if grep -qi qemu /sys/class/dmi/id/sys_vendor 2>/dev/null; then
      HW_VM_TYPE=qemu
    fi
  else
    if [[ -r /sys/class/dmi/id/chassis_type ]]; then
      read -r ct < /sys/class/dmi/id/chassis_type
    fi
    case $ct in
      8|9|10|14|30|31|32) HW_CHASSIS_RESULT=laptop ;;
      3|4|5|6|7|13|15|16|17|23|24|35|36) HW_CHASSIS_RESULT=desktop ;;
      *) HW_CHASSIS_RESULT=desktop ;;
    esac
    case $ct in
      30|31|32) HW_CONVERTIBLE=yes ;;
    esac
  fi

  cpu_vendor=$(awk -F: '/vendor_id/{gsub(/ /,"",$2);print $2;exit}' /proc/cpuinfo)
  case $cpu_vendor in
    GenuineIntel) HW_CPU=intel ;;
    AuthenticAMD) HW_CPU=amd ;;
    *) HW_CPU=unknown ;;
  esac

  while IFS= read -r line; do
    if [[ $line =~ \[([0-9a-fA-F]{4}):[0-9a-fA-F]{4}\] ]]; then
      vid=${BASH_REMATCH[1],,}
      case $vid in
        8086) hw_gpu_add intel ;;
        1002) hw_gpu_add amd ;;
        10de) hw_gpu_add nvidia ;;
        1af4|1b36|1234|15ad) hw_gpu_add virtual ;;
      esac
    fi
  done < <(lspci -nn 2>/dev/null | grep -E 'VGA compatible controller|3D controller|Display controller' || true)

  for p in /sys/class/input/event*; do
    [[ -e $p ]] || continue
    if udevadm info -q property -p "$p" 2>/dev/null | grep -q '^ID_INPUT_TOUCHSCREEN=1$'; then
      HW_TOUCH_RESULT=yes
      break
    fi
  done

  if lsusb 2>/dev/null | grep -qi fingerprint; then
    HW_FINGERPRINT_RESULT=yes
  else
    while IFS= read -r line; do
      if [[ $line =~ ID[[:space:]]([0-9a-fA-F]{4}): ]]; then
        vid=${BASH_REMATCH[1],,}
        case $vid in
          138a|27c6|08ff|147e|1c7a|2808|05ba)
            HW_FINGERPRINT_RESULT=yes
            break
            ;;
        esac
      fi
    done < <(lsusb 2>/dev/null || true)
  fi

  if [[ -n $(ls -A /sys/class/bluetooth 2>/dev/null || true) ]] \
     || lsusb 2>/dev/null | grep -qi bluetooth; then
    HW_BLUETOOTH_RESULT=yes
  fi

  for d in /sys/class/net/*/wireless; do
    if [[ -e $d ]]; then
      HW_WIFI=yes
      break
    fi
  done

  # Config overrides replace detected values (spec 8).
  if [[ $HW_CHASSIS != auto ]]; then
    HW_CHASSIS_RESULT=$HW_CHASSIS
  fi
  if [[ $HW_TOUCH != auto ]]; then
    HW_TOUCH_RESULT=$HW_TOUCH
  fi
  if [[ $HW_FINGERPRINT != auto ]]; then
    HW_FINGERPRINT_RESULT=$HW_FINGERPRINT
  fi
  if [[ $HW_BLUETOOTH != auto ]]; then
    HW_BLUETOOTH_RESULT=$HW_BLUETOOTH
  fi

  HW_SUMMARY=$HW_CHASSIS_RESULT
  if [[ $HW_VM == yes ]]; then
    HW_SUMMARY="vm ($HW_VM_TYPE)"
  fi
  HW_SUMMARY="$HW_SUMMARY, $HW_CPU cpu"
  local -a gpu_arr
  read -r -a gpu_arr <<< "$HW_GPUS"
  for vid in "${gpu_arr[@]}"; do
    HW_SUMMARY="$HW_SUMMARY, $vid gpu"
  done
  if [[ $HW_TOUCH_RESULT == yes ]]; then
    HW_SUMMARY="$HW_SUMMARY, touchscreen"
  fi
  if [[ $HW_FINGERPRINT_RESULT == yes ]]; then
    HW_SUMMARY="$HW_SUMMARY, fingerprint reader"
  fi
  if [[ $HW_BLUETOOTH_RESULT == yes ]]; then
    HW_SUMMARY="$HW_SUMMARY, bluetooth"
  fi
  if [[ $HW_WIFI == yes ]]; then
    HW_SUMMARY="$HW_SUMMARY, wifi"
  fi
}

# --------------------------------------------------------------------------
# Package lists (spec section 8.2)
# --------------------------------------------------------------------------

pkg_add() {
  if [[ -z ${PKG_SEEN[$1]:-} ]]; then
    PKG_SEEN[$1]=1
    PKGS_ALL+=("$1")
  fi
}

build_package_lists() {
  local p v xtra
  PKG_SEEN=()
  PKGS_ALL=()

  for p in base-system linux linux-firmware-network btrfs-progs grub-x86_64-efi \
           grub-btrfs grub-btrfs-runit efibootmgr dosfstools snapper inotify-tools \
           NetworkManager dbus elogind polkit chrony sudo bash-completion acpid \
           alsa-utils void-repo-nonfree \
           chezmoi git curl wget openssh gnupg age unzip xz tar rsync python3 \
           base-devel nano; do
    pkg_add "$p"
  done

  SV_FATAL=(dbus elogind polkitd NetworkManager chronyd acpid grub-btrfs)
  SV_OPTIONAL=()

  if [[ $SWAP == zram ]]; then
    pkg_add zramen
    SV_FATAL+=(zramen)
  fi
  if [[ $HW_CPU == intel ]]; then
    pkg_add intel-ucode
  fi
  if [[ $HW_CPU == intel || $HW_GPUS == *intel* ]]; then
    pkg_add linux-firmware-intel
  fi
  if [[ $HW_CPU == amd || $HW_GPUS == *amd* ]]; then
    pkg_add linux-firmware-amd
  fi
  if [[ $HW_GPUS == *intel* ]]; then
    for p in mesa-dri vulkan-loader mesa-vulkan-intel intel-video-accel intel-media-driver; do
      pkg_add "$p"
    done
  fi
  if [[ $HW_GPUS == *amd* ]]; then
    # mesa-vdpau no longer exists (dropped from Void's mesa packaging); VA-API
    # is the video decode path, libva-vdpau-driver bridges legacy VDPAU apps.
    for p in mesa-dri vulkan-loader mesa-vulkan-radeon mesa-vaapi libva-vdpau-driver; do
      pkg_add "$p"
    done
  fi
  if [[ $HW_GPUS == *nvidia* ]]; then
    for p in mesa-dri vulkan-loader mesa-nouveau-dri; do
      pkg_add "$p"
    done
  fi
  if [[ $HW_GPUS == *virtual* ]]; then
    pkg_add mesa-dri
  fi
  if [[ $HW_CPU == intel && ( $HW_CHASSIS_RESULT == laptop || $HW_CHASSIS_RESULT == desktop ) ]]; then
    pkg_add sof-firmware
  fi
  if [[ $HW_CHASSIS_RESULT == laptop ]]; then
    for p in tlp upower brightnessctl iw; do
      pkg_add "$p"
    done
    SV_OPTIONAL+=(tlp upower)
  fi
  if [[ $HW_VM == yes && $HW_VM_TYPE == qemu ]]; then
    pkg_add qemu-ga
    pkg_add spice-vdagent
    SV_OPTIONAL+=(qemu-ga spice-vdagentd)
  fi
  if [[ $HW_TOUCH_RESULT == yes ]]; then
    # the libinput CLI tools ship inside the libinput package itself
    pkg_add libinput
  fi
  if [[ $HW_CONVERTIBLE == yes || ( $HW_TOUCH_RESULT == yes && $HW_CHASSIS_RESULT == laptop ) ]]; then
    pkg_add iio-sensor-proxy
    SV_OPTIONAL+=(iio-sensor-proxy)
  fi
  if [[ $HW_FINGERPRINT_RESULT == yes ]]; then
    pkg_add fprintd
    pkg_add libfprint
  fi
  if [[ $HW_BLUETOOTH_RESULT == yes ]]; then
    pkg_add bluez
    SV_OPTIONAL+=(bluetoothd)
  fi
  if [[ -n $EXTRA_PACKAGES ]]; then
    read -r -a xtra <<< "$EXTRA_PACKAGES"
    for p in "${xtra[@]}"; do
      pkg_add "$p"
    done
  fi
}

# --------------------------------------------------------------------------
# Package and service probe (spec section 10.1) — fails before touching disk
# --------------------------------------------------------------------------

probe_packages() {
  local pkg svc

  # Lightweight package availability check: one xbps-query per package
  # (xbps-query accepts only a single package argument; batched call fails
  # with "too many arguments"). Each call uses -M to fetch repodata into RAM.
  for pkg in "${PKGS_ALL[@]}"; do
    if ! xbps-query -R -M --repository="$MIRROR/current" --repository="$MIRROR/current/nonfree" \
         "$pkg" >/dev/null; then
      echo "Package not found in repository: $pkg" >&2
      exit 3
    fi
  done

  local -a pairs=(dbus:dbus elogind:elogind polkit:polkitd \
                  chrony:chronyd acpid:acpid)
  if [[ $SWAP == zram ]]; then
    pairs+=(zramen:zramen)
  fi
  # -M everywhere: repository queries would otherwise read the (possibly
  # empty) on-disk cache instead of the live mirror.
  for svc in "${pairs[@]}"; do
    pkg=${svc%%:*}
    svc=${svc##*:}
    if xbps-query -R -M --repository="$MIRROR/current" -f "$pkg" | grep -q "etc/sv/$svc"; then
      continue
    fi
    echo "Package $pkg does not provide service $svc." >&2
    exit 3
  done

  # NetworkManager: ship our own runit service if the package does not
  # provide one (verified on some Void releases/repos where the service
  # directory is absent from the binary package).
  if xbps-query -R -M --repository="$MIRROR/current" -f NetworkManager | grep -q "etc/sv/NetworkManager"; then
    NETWORKMANAGER_OWN=0
  else
    NETWORKMANAGER_OWN=1
  fi

  # The grub-btrfs runit service ships with the main grub-btrfs package
  # (grub-btrfs-runit is an empty transitional package). If neither ships a
  # grub-btrfs service directory we provide our own run script instead of
  # failing (spec 10.1).
  if xbps-query -R -M --repository="$MIRROR/current" -f grub-btrfs | grep -q "etc/sv/grub-btrfs"; then
    GRUB_BTRFS_OWN=0
  else
    GRUB_BTRFS_OWN=1
  fi
}

# --------------------------------------------------------------------------
# Interactive UI (spec sections 7.1, 6 prompt rules)
# --------------------------------------------------------------------------

choose_disk() {
  if (( YES_MODE == 1 )) || [[ -n ${TARGET_DISK:-} ]]; then
    return 0
  fi
  local entries=() dev dtype size model sizeb devname choice
  while read -r dev dtype; do
    [[ -n $dev ]] || continue
    devname=${dev##*/}
    case $devname in
      loop*|sr*|zram*|ram*) continue ;;
    esac
    [[ $dtype == disk ]] || continue
    if [[ -n $(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null) ]]; then
      continue
    fi
    sizeb=$(lsblk -dbno SIZE "$dev" 2>/dev/null || echo 0)
    [[ $sizeb =~ ^[0-9]+$ ]] || continue
    (( sizeb >= MIN_DISK_BYTES )) || continue
    size=$(lsblk -dno SIZE "$dev")
    model=$(lsblk -dno MODEL "$dev" 2>/dev/null || true)
    [[ -n $model ]] || model="unknown model"
    entries+=("$dev" "$size  $model")
  done < <(lsblk -dpno NAME,TYPE)

  if [[ ${#entries[@]} -eq 0 ]]; then
    echo "No eligible disk found." >&2
    exit 3
  fi
  if ! choice=$(dialog --clear --title "Select target disk" \
      --menu "ALL DATA ON THE SELECTED DISK WILL BE ERASED." 20 76 10 \
      "${entries[@]}" 3>&1 1>&2 2>&3); then
    exit 4
  fi
  TARGET_DISK=$choice
}

prompt_value() {
  local var=$1 text=$2 val
  while true; do
    if ! val=$(dialog --clear --title "$var" --inputbox "$text" 10 70 \
        "${!var:-}" 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if validate_one "$var" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    dialog --msgbox "Invalid value for $var: $VALIDATE_REASON" 10 70 || exit 4
  done
}

prompt_password() {
  local p1 p2
  while true; do
    if ! p1=$(dialog --clear --title "USER_PASSWORD" --passwordbox \
        "Password for the new user" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if ! p2=$(dialog --clear --title "USER_PASSWORD" --passwordbox \
        "Repeat password" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if [[ -z $p1 ]]; then
      dialog --msgbox "Password must not be empty." 10 70 || exit 4
      continue
    fi
    if [[ $p1 != "$p2" ]]; then
      dialog --msgbox "Passwords do not match." 10 70 || exit 4
      continue
    fi
    USER_PASSWORD=$p1
    return 0
  done
}

prompt_root_password() {
  local p1 p2
  while true; do
    if ! p1=$(dialog --clear --title "ROOT_PASSWORD" --passwordbox \
        "Root password for console recovery" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if ! p2=$(dialog --clear --title "ROOT_PASSWORD" --passwordbox \
        "Repeat root password" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if [[ -z $p1 ]]; then
      dialog --msgbox "Root password must not be empty." 10 70 || exit 4
      continue
    fi
    if [[ $p1 != "$p2" ]]; then
      dialog --msgbox "Root passwords do not match." 10 70 || exit 4
      continue
    fi
    ROOT_PASSWORD=$p1
    return 0
  done
}

prompt_menu() {  # $1 = var, $2 = title, $3 = prompt text, rest = tag/desc pairs
  local var=$1 title=$2 text=$3 choice
  shift 3
  if ! choice=$(dialog --clear --title "$title" --default-item "${!var:-}" \
      --menu "$text" 20 76 10 "$@" 3>&1 1>&2 2>&3); then
    exit 4
  fi
  printf -v "$var" '%s' "$choice"
}

prompt_timezone() {
  local zones=() entries=() z
  mapfile -t zones < <(find /usr/share/zoneinfo -type f \
      ! -path '*/posix/*' ! -path '*/right/*' \
      ! -name '*.tab' ! -name leapseconds ! -name tzdata.zi \
      ! -name posixrules ! -name SECURITY ! -name '+VERSION' \
      -printf '%P\n' | sort)
  if (( ${#zones[@]} == 0 )); then
    echo "Warning: no timezone list found under /usr/share/zoneinfo, falling back to manual input." >&2
    prompt_value TIMEZONE "Timezone (e.g. Europe/Berlin)"
    return 0
  fi
  for z in "${zones[@]}"; do entries+=("$z" ""); done
  prompt_menu TIMEZONE "TIMEZONE" "Select timezone" "${entries[@]}"
}

prompt_locale() {
  local names=() entries=() n
  mapfile -t names < <(sed -e 's/^#//' -e 's/^[[:space:]]*//' /etc/default/libc-locales 2>/dev/null \
      | awk '$2 == "UTF-8" {print $1}' | sort -u)
  if (( ${#names[@]} == 0 )); then
    echo "Warning: no locale list found in /etc/default/libc-locales, falling back to manual input." >&2
    prompt_value LOCALE "Locale (e.g. en_US.UTF-8)"
    return 0
  fi
  for n in "${names[@]}"; do entries+=("$n" ""); done
  prompt_menu LOCALE "LOCALE" "Select locale" "${entries[@]}"
}

prompt_missing() {
  if (( YES_MODE == 1 )); then
    return 0
  fi
  if ! is_config_set HOSTNAME; then
    prompt_value HOSTNAME "Hostname"
  fi
  if ! is_config_set KEYMAP; then
    prompt_value KEYMAP "Console keymap"
  fi
  # The password must be entered using the same layout the installed system
  # will use at login. The live ISO's current keymap may differ.
  if ! loadkeys "$KEYMAP"; then
    echo "Failed to load console keymap: $KEYMAP" >&2
    exit 3
  fi
  if ! is_config_set USERNAME; then
    prompt_value USERNAME "Username for the new user"
  fi
  if ! is_config_set USER_PASSWORD && ! is_config_set USER_PASSWORD_HASH; then
    prompt_password
  fi
  if ! is_config_set ROOT_PASSWORD && ! is_config_set ROOT_PASSWORD_HASH; then
    prompt_root_password
  fi
  if ! is_config_set TIMEZONE; then
    prompt_timezone
  fi
  if ! is_config_set LOCALE; then
    prompt_locale
  fi
  if ! is_config_set CHEZMOI_REPO; then
    prompt_value CHEZMOI_REPO "chezmoi dotfiles repo (https://... or GitHub user/repo, empty to skip)"
  fi
}

# --------------------------------------------------------------------------
# Final confirmation (spec section 7.2)
# --------------------------------------------------------------------------

confirm() {
  if (( YES_MODE == 1 )); then
    return 0
  fi
  local size model answer
  size=$(lsblk -dno SIZE "$TARGET_DISK")
  model=$(lsblk -dno MODEL "$TARGET_DISK" 2>/dev/null || true)
  [[ -n $model ]] || model="unknown model"
  echo "Installation summary"
  printf '  %-12s %s  (%s, %s)   <-- WILL BE ERASED\n' "Disk:" "$TARGET_DISK" "$size" "$model"
  printf '  %-12s %s\n' "Hostname:" "$HOSTNAME"
  printf '  %-12s %s\n' "User:" "$USERNAME"
  printf '  %-12s %s\n' "Root login:" "enabled (separate password)"
  printf '  %-12s %s\n' "Timezone:" "$TIMEZONE"
  printf '  %-12s %s\n' "Locale:" "$LOCALE"
  printf '  %-12s %s\n' "Keymap:" "$KEYMAP"
  printf '  %-12s %s\n' "Swap:" "$SWAP"
  printf '  %-12s %s\n' "Hardware:" "${HW_SUMMARY:-unknown}"
  printf '  %-12s %s\n' "Dotfiles:" "${CHEZMOI_REPO:-none}"
  echo "Press y to erase the disk and install, any other key aborts:"
  read -r -n1 -s answer || answer=""
  if [[ $answer != y && $answer != Y ]]; then
    echo "Aborted."
    exit 4
  fi
}

# --------------------------------------------------------------------------
# Disk layout (spec section 9)
# --------------------------------------------------------------------------

part() {  # $1 = partition number
  case "$TARGET_DISK" in
    *[0-9]) printf '%sp%s' "$TARGET_DISK" "$1" ;;   # nvme0n1 -> nvme0n1p1, mmcblk0 -> mmcblk0p1
    *)      printf '%s%s'  "$TARGET_DISK" "$1" ;;   # sda -> sda1
  esac
}

partition_disk() {
  umount -R /mnt 2>/dev/null || true

  # Targeted swapoff: only deactivate swap on the target disk.
  # swapoff -a would take down unrelated system swap (other disks, zram).
  # Match partitions of TARGET_DISK: /dev/sdaN, /dev/nvme0n1pN, /dev/mmcblk0pN, etc.
  local swdev
  while IFS= read -r swdev; do
    case $swdev in
      "$TARGET_DISK"[0-9]*|"$TARGET_DISK"p[0-9]*)
        swapoff "$swdev" || true ;;
    esac
  done < <(awk 'NR>1{print $1}' /proc/swaps)

  wipefs -af "$TARGET_DISK"
  # sfdisk (util-linux, shipped by the ISO) replaces sgdisk: GPT label,
  # type GUIDs and partition names. It re-reads the partition table itself,
  # so no partprobe is needed.
  sfdisk --wipe always "$TARGET_DISK" <<'EOF'
label: gpt
size=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI"
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="VOID"
EOF
  udevadm settle
  local i=0
  until [[ -b $(part 1) && -b $(part 2) ]]; do
    if (( i >= 20 )); then
      echo "Partitions did not appear on $TARGET_DISK" >&2
      return 1
    fi
    sleep 0.5
    i=$((i + 1))
  done
}

format_disk() {
  mkfs.vfat -F32 -n EFI "$(part 1)"
  mkfs.btrfs -f -L VOID "$(part 2)"
  ROOT_UUID=$(blkid -s UUID -o value "$(part 2)")
  ESP_UUID=$(blkid -s UUID -o value "$(part 1)")
}

mount_layout() {
  local sv
  mount "$(part 2)" /mnt                       # top level (subvolid 5)
  for sv in @ @home @snapshots @var_log @var_cache_xbps @var_tmp; do
    btrfs subvolume create "/mnt/$sv"
  done
  umount /mnt

  mount -o "$BTRFS_OPTS,subvol=@" "$(part 2)" /mnt
  mkdir -p /mnt/{home,.snapshots,var/log,var/cache/xbps,var/tmp,boot/efi}
  mount -o "$BTRFS_OPTS,subvol=@home"           "$(part 2)" /mnt/home
  mount -o "$BTRFS_OPTS,subvol=@var_log"        "$(part 2)" /mnt/var/log
  mount -o "$BTRFS_OPTS,subvol=@var_cache_xbps" "$(part 2)" /mnt/var/cache/xbps
  mount -o "$BTRFS_OPTS,subvol=@var_tmp"        "$(part 2)" /mnt/var/tmp
  # @snapshots is deliberately not mounted yet: snapper creates a nested
  # .snapshots subvolume first, which setup_snapper replaces (spec 10.4/10.8).
  mount -o umask=0077 "$(part 1)" /mnt/boot/efi
}

# --------------------------------------------------------------------------
# Bootstrap (spec sections 10.5, 10.6)
# --------------------------------------------------------------------------

bootstrap_system() {
  local d
  case $1 in
    prepare)
      mkdir -p /mnt/var/db/xbps/keys
      cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

      # XBPS skips -S when -n is set. Sync separately so a fresh target has
      # on-disk repository indexes before the dry-run resolves packages.
      TMPDIR=/mnt/var/tmp \
      XBPS_ARCH=x86_64 xbps-install -S -y -r /mnt \
        --cachedir /mnt/var/cache/xbps \
        -R "$MIRROR/current" -R "$MIRROR/current/nonfree" || {
          echo "Repository synchronization against /mnt failed. See output above." >&2
          exit 1
        }

      # Full dependency + disk-space validation uses the persisted indexes
      # and the same disk-backed root and cache as the real transaction.
      local rc=0
      TMPDIR=/mnt/var/tmp \
      XBPS_ARCH=x86_64 xbps-install -n -y -r /mnt \
        --cachedir /mnt/var/cache/xbps \
        -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
        "${PKGS_ALL[@]}" || rc=$?
      if (( rc != 0 )); then
        echo "Dependency/disk-space validation against /mnt failed. See output above." >&2
        exit 1
      fi
      ;;
    install)
      TMPDIR=/mnt/var/tmp \
      XBPS_ARCH=x86_64 xbps-install -S -y -r /mnt \
        --cachedir /mnt/var/cache/xbps \
        -R "$MIRROR/current" -R "$MIRROR/current/nonfree" \
        "${PKGS_ALL[@]}"
      if [[ $MIRROR != https://repo-default.voidlinux.org ]]; then
        mkdir -p /mnt/etc/xbps.d
        cp /mnt/usr/share/xbps.d/*-repository-*.conf /mnt/etc/xbps.d/
        sed -i "s|https://repo-default.voidlinux.org|$MIRROR|g" /mnt/etc/xbps.d/*-repository-*.conf
      fi
      for d in dev proc sys; do
        mount --rbind "/$d" "/mnt/$d"
        mount --make-rslave "/mnt/$d"
      done
      cp /etc/resolv.conf /mnt/etc/resolv.conf
      ;;
  esac
}

# --------------------------------------------------------------------------
# System configuration (spec section 10.7)
# --------------------------------------------------------------------------

write_fstab() {
  local opts="rw,noatime,compress=zstd:1,discard=async"
  {
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/"              btrfs "$opts,subvol=@"
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/home"          btrfs "$opts,subvol=@home"
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/.snapshots"    btrfs "$opts,subvol=@snapshots"
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/var/log"       btrfs "$opts,subvol=@var_log"
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/var/cache/xbps" btrfs "$opts,subvol=@var_cache_xbps"
    printf 'UUID=%s  %-17s %-6s %-61s   0 0\n' "$ROOT_UUID" "/var/tmp"       btrfs "$opts,subvol=@var_tmp"
    printf 'UUID=%s  %-17s %-6s %-61s   0 2\n' "$ESP_UUID"  "/boot/efi"      vfat  "umask=0077"
    printf '%-41s  %-17s %-6s %-61s   0 0\n'   "tmpfs"     "/tmp"            tmpfs "defaults,nosuid,nodev"
  } > /mnt/etc/fstab
}

configure_system() {
  local kv k v locale_esc=${LOCALE//./\\.}

  echo "$HOSTNAME" > /mnt/etc/hostname
  printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$HOSTNAME" > /mnt/etc/hosts

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

  if grep -qE '^#?KEYMAP=' /mnt/etc/rc.conf; then
    sed -i -E "s|^#?KEYMAP=.*|KEYMAP=\"$KEYMAP\"|" /mnt/etc/rc.conf
  else
    printf 'KEYMAP="%s"\n' "$KEYMAP" >> /mnt/etc/rc.conf
  fi

  if ! grep -qiE "^#?[[:space:]]*${locale_esc}[[:space:]]+UTF-8[[:space:]]*$" /mnt/etc/default/libc-locales; then
    echo "Locale not available: $LOCALE" >&2
    exit 2
  fi
  sed -i -E "s|^#[[:space:]]*(${locale_esc}[[:space:]]+UTF-8)[[:space:]]*$|\1|" /mnt/etc/default/libc-locales
  echo "LANG=$LOCALE" > /mnt/etc/locale.conf
  chroot /mnt xbps-reconfigure -f glibc-locales

  write_fstab

  printf '%%wheel ALL=(ALL:ALL) ALL\n' > /mnt/etc/sudoers.d/10-wheel
  chmod 0440 /mnt/etc/sudoers.d/10-wheel

  if [[ $SWAP == zram ]]; then
    for kv in ZRAM_COMP_ALGORITHM=zstd ZRAM_PRIORITY=32767 ZRAM_SIZE=50 ZRAM_MAX_SIZE=8192 ZRAMEN_QUIET=1; do
      k=${kv%%=*}
      v=${kv#*=}
      if grep -qE "^[# ]*export $k=" /mnt/etc/sv/zramen/conf; then
        sed -i -E "s|^[# ]*export $k=.*|export $k=$v|" /mnt/etc/sv/zramen/conf
      else
        echo "Warning: $k not found in shipped zramen conf, appended." >&2
        echo "export $k=$v" >> /mnt/etc/sv/zramen/conf
      fi
    done
  fi
}

# --------------------------------------------------------------------------
# snapper / GRUB / services / user (spec sections 10.8-10.11)
# --------------------------------------------------------------------------

setup_snapper() {
  chroot /mnt /bin/bash -s <<'CHROOT_EOF'
set -eu
# /.snapshots exists as an empty directory (created by mount_layout); snapper
# needs the path absent to create its nested subvolume, which is replaced
# right after with the @snapshots subvolume via fstab.
rmdir /.snapshots 2>/dev/null || true
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount /.snapshots
chmod 750 /.snapshots
snapper --no-dbus -c root set-config \
  "TIMELINE_CREATE=no" "TIMELINE_CLEANUP=no" \
  "NUMBER_CLEANUP=yes" "NUMBER_MIN_AGE=0" \
  "NUMBER_LIMIT=10" "NUMBER_LIMIT_IMPORTANT=10" \
  "EMPTY_PRE_POST_CLEANUP=no"
CHROOT_EOF
}

set_grub_default() {  # $1 = key, $2 = value
  local key=$1 val=$2 f=/mnt/etc/default/grub
  if grep -q "^$key=" "$f"; then
    sed -i "s|^$key=.*|$key=\"$val\"|" "$f"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$f"
  fi
}

setup_grub() {
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
  chroot /mnt xbps-reconfigure -fa
  set_grub_default GRUB_CMDLINE_LINUX_DEFAULT "loglevel=4"
  set_grub_default GRUB_DISABLE_OS_PROBER "true"
  set_grub_default GRUB_TIMEOUT "3"
  chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

enable_sv() {  # $1 = service, $2 = fatal|optional
  if [[ -d /mnt/etc/sv/$1 ]]; then
    ln -sf "/etc/sv/$1" "/mnt/etc/runit/runsvdir/default/$1"
  elif [[ $2 == fatal ]]; then
    echo "Service directory /etc/sv/$1 missing in target." >&2
    return 1
  else
    echo "Warning: service $1 not available, skipped." >&2
  fi
}

enable_services() {
  local svc
  if (( GRUB_BTRFS_OWN == 1 )); then
    mkdir -p /mnt/etc/sv/grub-btrfs
    # No --syslog: v1 installs no syslog daemon (spec decision 18).
    cat > /mnt/etc/sv/grub-btrfs/run <<'EOF'
#!/bin/sh
exec grub-btrfsd /.snapshots
EOF
    chmod 0755 /mnt/etc/sv/grub-btrfs/run
  fi
  if (( NETWORKMANAGER_OWN == 1 )); then
    mkdir -p /mnt/etc/sv/NetworkManager
    cat > /mnt/etc/sv/NetworkManager/run <<'EOF'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1
exec NetworkManager -n >/dev/null 2>&1
EOF
    chmod 0755 /mnt/etc/sv/NetworkManager/run
  fi
  for svc in "${SV_FATAL[@]}"; do
    enable_sv "$svc" fatal
  done
  for svc in "${SV_OPTIONAL[@]}"; do
    enable_sv "$svc" optional
  done
}

create_user() {
  local account_status
  chroot /mnt useradd -m -s "$USER_SHELL" -G wheel,audio,video,input "$USERNAME"
  # Passwords are passed on stdin only: never on disk outside /etc/shadow,
  # never in the process list, never in the chroot environment.
  if [[ -v USER_PASSWORD_HASH ]]; then
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD_HASH" | chroot /mnt chpasswd -e
  else
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot /mnt chpasswd
  fi

  # Set an independent root password; root remains available at the console
  # as a recovery account if the regular user cannot authenticate.
  if [[ -v ROOT_PASSWORD_HASH ]]; then
    printf 'root:%s\n' "$ROOT_PASSWORD_HASH" | chroot /mnt chpasswd -e
  else
    printf 'root:%s\n' "$ROOT_PASSWORD" | chroot /mnt chpasswd
  fi

  # Catch incomplete account setup before reporting a successful install.
  account_status=$(chroot /mnt passwd -S "$USERNAME")
  if [[ $account_status != "$USERNAME P "* ]]; then
    echo "User account $USERNAME does not have an active password after setup." >&2
    exit 1
  fi
  account_status=$(chroot /mnt passwd -S root)
  if [[ $account_status != "root P "* ]]; then
    echo "Root account does not have an active password after setup." >&2
    exit 1
  fi
}

# --------------------------------------------------------------------------
# chezmoi dotfiles (spec section 13)
# --------------------------------------------------------------------------

apply_chezmoi() {
  if [[ -z $CHEZMOI_REPO ]]; then
    return 0
  fi
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" > /mnt/etc/sudoers.d/99-installer
  chmod 0440 /mnt/etc/sudoers.d/99-installer
  if ! chroot /mnt su - "$USERNAME" -c "chezmoi init --apply --force '$CHEZMOI_REPO'" </dev/null; then
    CHEZMOI_FAILED=1
  fi
  rm -f /mnt/etc/sudoers.d/99-installer
}

# --------------------------------------------------------------------------
# xbps snapshot wrappers + initial snapshot (spec sections 12, 10.13)
# --------------------------------------------------------------------------

install_wrappers() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'WRAPPER_EOF'
#!/bin/bash
# xbps snapshot wrapper — installed as /usr/local/bin/xbps-install and /usr/local/bin/xbps-remove
cmd=${0##*/}
real=/usr/bin/$cmd
[ -x "$real" ] || { echo "$cmd: $real not found" >&2; exit 127; }

want_snapshot() {
  [ "$(id -u)" -eq 0 ] || return 1
  [ -z "${XBPS_NO_SNAPSHOT:-}" ] || return 1
  [ -r /etc/snapper/configs/root ] || return 1
  local argch pkgs=0 act=0 opt c
  case $cmd in
    xbps-install) argch=CcrR ;;   # short options that take an argument
    xbps-remove)  argch=Ccr  ;;   # (-R is a plain flag for xbps-remove)
    *) return 1 ;;
  esac
  while [ $# -gt 0 ]; do
    case $1 in
      --) shift; pkgs=$((pkgs + $#)); break ;;
      --rootdir|--rootdir=*|--dry-run|--download-only|--help|--version) return 1 ;;
      --update) [ "$cmd" = xbps-install ] && act=1 ;;
      --remove-orphans) [ "$cmd" = xbps-remove ] && act=1 ;;
      --config|--cachedir|--repository) shift ;;
      --*) ;;
      -?*)
        opt=${1#-}
        while [ -n "$opt" ]; do
          c=${opt:0:1}; opt=${opt:1}
          case $c in
            n|D|h|V|r) return 1 ;;   # dry-run, download-only, help, version, other rootdir
            u) [ "$cmd" = xbps-install ] && act=1 ;;
            o) [ "$cmd" = xbps-remove ]  && act=1 ;;
          esac
          case $argch in
            *"$c"*) [ -z "$opt" ] && shift; opt= ;;   # option consumes the rest, or the next word
          esac
        done ;;
      *) pkgs=$((pkgs + 1)) ;;
    esac
    shift
  done
  [ $((pkgs + act)) -gt 0 ]
}

if want_snapshot "$@"; then
  desc="$cmd $*"
  pre=$(snapper --no-dbus -c root create -t pre -p -c number -d "$desc" 2>/dev/null) || pre=
  [ -n "$pre" ] || echo "warning: could not create pre snapshot, continuing without snapshot" >&2
  "$real" "$@"; rc=$?
  if [ -n "$pre" ]; then
    snapper --no-dbus -c root create -t post --pre-number "$pre" -c number -d "$desc" >/dev/null 2>&1 \
      || echo "warning: could not create post snapshot" >&2
    snapper --no-dbus -c root cleanup number >/dev/null 2>&1 || true
  fi
  exit $rc
fi
exec "$real" "$@"
WRAPPER_EOF
  # Installed after all installer package transactions: nothing during the
  # installation itself must trigger snapshots (spec 12.1).
  install -Dm0755 "$tmp" /mnt/usr/local/bin/xbps-install
  install -Dm0755 "$tmp" /mnt/usr/local/bin/xbps-remove
  rm -f "$tmp"
}

initial_snapshot() {
  chroot /mnt snapper --no-dbus -c root create -c number -d "Initial installation"
  chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

# --------------------------------------------------------------------------
# Finalize, error handling (spec sections 10.14, 10)
# --------------------------------------------------------------------------

finalize() {
  rm -f /mnt/etc/sudoers.d/99-installer     # temporary NOPASSWD rule (section 13)
  rm -f /mnt/etc/resolv.conf                # NetworkManager manages it at boot
  umount -R /mnt
  sync
  echo "Installation complete. Remove the installation medium and reboot."
  if [[ ${HW_GPUS:-} == *nvidia* ]]; then
    echo "NVIDIA GPU detected: nouveau driver installed. Proprietary driver not included."
  fi
  if [[ ${HW_FINGERPRINT_RESULT:-} == yes ]]; then
    echo "Fingerprint reader detected: fprintd installed. Enrol with 'fprintd-enroll' and add pam_fprintd to /etc/pam.d yourself to use it for login/sudo."
  fi
  if (( CHEZMOI_FAILED == 1 )); then
    echo "Warning: chezmoi failed. After first boot run:  chezmoi init --apply $CHEZMOI_REPO"
  fi
  exit 0
}

cleanup() {
  rm -f /mnt/etc/sudoers.d/99-installer 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
}

on_error() {
  echo "Installation failed at step $CURRENT_STEP_N ($CURRENT_STEP_NAME), line $1." >&2
  exit 1
}

# --------------------------------------------------------------------------
# Step orchestration (spec section 10)
# --------------------------------------------------------------------------

run_step() {  # $1 = N, $2 = name, rest = function
  CURRENT_STEP_N=$1
  CURRENT_STEP_NAME=$2
  echo "==> [$1/16] $2"
  shift 2
  "$@"
}

load_settings() {
  if [[ -n $CONFIG_FILE ]]; then
    load_config "$CONFIG_FILE"
  fi
  apply_defaults
}

step_interactive() {
  choose_disk
  prompt_missing
}

step_filesystems() {
  format_disk
  mount_layout
}

bootstrap_prepare() { bootstrap_system prepare; }
bootstrap_install()  { bootstrap_system install; }

step_configure() {
  configure_system
  setup_snapper
  setup_grub
  enable_services
  create_user
}

step_wrappers() {
  install_wrappers
  initial_snapshot
}

main() {
  trap cleanup EXIT
  trap 'on_error $LINENO' ERR

  echo "void-installer $INSTALLER_VERSION"
  parse_args "$@"

  run_step  1 "Parse arguments and load configuration" load_settings
  run_step  2 "Preflight checks" preflight
  run_step  3 "Detect hardware" detect_hardware
  run_step  4 "Build package lists" build_package_lists
  run_step  5 "Select disk and prompt for missing values" step_interactive
  run_step  6 "Validate configuration" validate_all
  run_step  7 "Probe packages and services" probe_packages
  run_step  8 "Confirm installation" confirm
  run_step  9 "Partition disk" partition_disk
  run_step 10 "Create filesystems and mount" step_filesystems
  run_step 11 "Prepare target for bootstrap" bootstrap_prepare
  run_step 12 "Install packages" bootstrap_install
  run_step 13 "Configure system" step_configure
  run_step 14 "Apply chezmoi dotfiles" apply_chezmoi
  run_step 15 "Install xbps wrappers and initial snapshot" step_wrappers
  run_step 16 "Finalize" finalize
}

main "$@"

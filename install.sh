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

INSTALLER_VERSION="1.3.15"
INSTALLER_TOTAL_STEPS=24
BTRFS_OPTS="rw,noatime,compress=zstd:1,discard=async"
MIN_DISK_BYTES=21474836480   # 20 GiB
GRUB_BTRFS_OWN=0             # set by probe_packages when grub-btrfs-runit ships no service dir
NETWORKMANAGER_OWN=0         # set by probe_packages when NetworkManager ships no service dir
CHEZMOI_FAILED=0
CURRENT_STEP_N=0
CURRENT_STEP_NAME="startup"
VALIDATE_REASON=""
CONFIG_SET=" "               # " KEY1 KEY2 ... " — keys that came from the config file
declare -a INSTALL_MOUNTS=()
INSTALLER_SUDOERS_CREATED=0
INSTALLER_LOG=""
INSTALL_STATE=""
INSTALL_STATE_STEP=0
INSTALL_STATE_CHECKPOINT="none"
INSTALL_STATUS="active"
RESUME_MODE=0
REPAIR_MODE=0
ROOT_PARTITION=""
ESP_PARTITION=""
REPAIR_ACTION=""
REPAIR_USER=""
PROBE_DIR=""
PROBE_ROOT=""
PROBE_CONF=""

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
       install.sh --resume ROOT_PARTITION
       install.sh --repair ROOT_PARTITION [--action check|chroot|password|grub|initramfs] [--user USER]

  --config FILE  read settings from FILE (default: ./install.conf if it exists)
  --yes          unattended mode: no dialogs, no confirmation; every value
                 without a default must be present in the config
  --resume DEV   safely resume an incomplete install on its Btrfs root partition
  --repair DEV   mount an existing install and run a non-destructive repair action
  --action NAME  repair action: check, chroot, password, grub, or initramfs
  --user USER    account to reset with --action password (root is allowed)
  --help         print this help and exit
EOF
}

parse_args() {
  CONFIG_FILE=""
  YES_MODE=0
  RESUME_MODE=0
  REPAIR_MODE=0
  ROOT_PARTITION=""
  REPAIR_ACTION=""
  REPAIR_USER=""
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
      --resume|--repair)
        if [[ -z ${2:-} || -n $ROOT_PARTITION ]]; then usage; exit 2; fi
        ROOT_PARTITION=$2
        if [[ $1 == --resume ]]; then RESUME_MODE=1; else REPAIR_MODE=1; fi
        shift 2
        ;;
      --action)
        [[ -n ${2:-} && -z $REPAIR_ACTION ]] || { usage; exit 2; }
        REPAIR_ACTION=$2
        shift 2
        ;;
      --user)
        [[ -n ${2:-} && -z $REPAIR_USER ]] || { usage; exit 2; }
        REPAIR_USER=$2
        shift 2
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
  if (( RESUME_MODE + REPAIR_MODE > 1 )); then usage; exit 2; fi
  if (( RESUME_MODE == 1 )); then
    if [[ -n $CONFIG_FILE || $YES_MODE == 1 || -n $REPAIR_ACTION || -n $REPAIR_USER ]]; then usage; exit 2; fi
  elif (( REPAIR_MODE == 1 )); then
    if [[ -n $CONFIG_FILE || $YES_MODE == 1 ]]; then usage; exit 2; fi
    case $REPAIR_ACTION in ""|check|chroot|password|grub|initramfs) ;; *) usage; exit 2 ;; esac
    if [[ -n $REPAIR_USER && $REPAIR_ACTION != password ]]; then usage; exit 2; fi
  elif [[ -n $REPAIR_ACTION || -n $REPAIR_USER ]]; then
    usage; exit 2
  fi
  if (( RESUME_MODE == 0 && REPAIR_MODE == 0 )) && [[ -z $CONFIG_FILE && -f ./install.conf ]]; then
    CONFIG_FILE=./install.conf
  fi
}

# The config is parsed, never sourced: sourcing would execute arbitrary code
# and expand $ inside values (destroying e.g. a '$6$...' password hash).
load_config() {
  local file=$1 line key val line_number=0
  if [[ ! -f $file || ! -r $file ]]; then
    echo "Cannot read config file: $file" >&2
    exit 2
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    line=${line%$'\r'}
    if [[ -z $line || $line == \#* ]]; then
      continue
    fi
    if ! [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      echo "Invalid config syntax in $file at line $line_number." >&2
      exit 2
    fi
    key=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    case $key in
      TARGET_DISK|HOSTNAME|USERNAME|USER_PASSWORD|USER_PASSWORD_HASH|\
      ROOT_PASSWORD|ROOT_PASSWORD_HASH|USER_SHELL|\
      TIMEZONE|LOCALE|KEYMAP|MIRROR|SWAP|CHEZMOI_REPO|EXTRA_PACKAGES|HW_CHASSIS|\
      CHEZMOI_MODE|WIFI_SSID|WIFI_SECURITY|WIFI_PASSWORD|WIFI_HIDDEN|\
      HW_TOUCH|HW_FINGERPRINT|HW_BLUETOOTH)
        ;;
      *)
        echo "Unsupported config key $key in $file at line $line_number." >&2
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
  [[ -v CHEZMOI_MODE ]] || CHEZMOI_MODE=first-login
  [[ -v WIFI_SSID ]] || WIFI_SSID=""
  [[ -v WIFI_SECURITY ]] || WIFI_SECURITY=wpa-psk
  [[ -v WIFI_HIDDEN ]] || WIFI_HIDDEN=no
  WIFI_SETUP=no
  if [[ -n $WIFI_SSID ]]; then
    WIFI_SETUP=yes
  fi
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
derive_desktop_keymap() {  # named console keymap -> XKB layout/variant/model
  local keymap=$1
  keymap=${keymap%.gz}
  keymap=${keymap%.map}
  XKB_LAYOUT=""
  XKB_VARIANT=""
  XKB_MODEL=pc105
  # These are layout conversions, not filename guesses. Unknown/custom maps
  # must not silently give the desktop a different keyboard than the console.
  case $keymap in
    us) XKB_LAYOUT=us ;;
    uk) XKB_LAYOUT=gb ;;
    de|de-latin1) XKB_LAYOUT=de ;;
    de-latin1-nodeadkeys) XKB_LAYOUT=de; XKB_VARIANT=nodeadkeys ;;
    de_CH-latin1) XKB_LAYOUT=ch ;;
    fr_CH-latin1) XKB_LAYOUT=ch; XKB_VARIANT=fr ;;
    fr|fr-latin0|fr-latin1) XKB_LAYOUT=fr ;;
    fr-latin9) XKB_LAYOUT=fr; XKB_VARIANT=latin9 ;;
    fr-bepo|fr-bepo-latin9) XKB_LAYOUT=fr; XKB_VARIANT=bepo ;;
    br-abnt|br-abnt2|br-latin1-abnt2) XKB_LAYOUT=br; XKB_MODEL=abnt2 ;;
    dvorak|ANSI-dvorak) XKB_LAYOUT=us; XKB_VARIANT=dvorak ;;
    dvorak-programmer) XKB_LAYOUT=us; XKB_VARIANT=dvp ;;
    dvorak-l|dvorak-r) XKB_LAYOUT=us; XKB_VARIANT=$keymap ;;
    es) XKB_LAYOUT=es ;;
    it) XKB_LAYOUT=it ;;
    pt|pt-latin1) XKB_LAYOUT=pt ;;
    be-latin1) XKB_LAYOUT=be ;;
    dk|dk-latin1) XKB_LAYOUT=dk ;;
    'fi'|fi-latin1) XKB_LAYOUT='fi' ;;
    no|no-latin1) XKB_LAYOUT=no ;;
    sv-latin1) XKB_LAYOUT=se ;;
    pl2) XKB_LAYOUT=pl ;;
    cz|cz-qwertz) XKB_LAYOUT=cz ;;
    cz-qwerty) XKB_LAYOUT=cz; XKB_VARIANT=qwerty ;;
    sk-qwertz) XKB_LAYOUT=sk ;;
    sk-qwerty) XKB_LAYOUT=sk; XKB_VARIANT=qwerty ;;
    hu) XKB_LAYOUT=hu ;;
    *)
      VALIDATE_REASON="has no supported Wayfire/XKB conversion; choose a named map such as us, uk, de, de-latin1-nodeadkeys, fr, fr-latin9, br-abnt2, or dvorak"
      return 1
      ;;
  esac
}

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
      derive_desktop_keymap "$val" || return 1
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
        if ! [[ $val =~ ^https://[^/@?#[:space:]]+$ || $val =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
          VALIDATE_REASON="must be an https:// URL or a GitHub user/repo (or empty to skip)"
          return 1
        fi
      fi
      ;;
    CHEZMOI_MODE)
      if [[ $val != first-login && $val != install ]]; then
        VALIDATE_REASON="must be first-login or install"
        return 1
      fi
      ;;
    WIFI_SSID)
      local LC_ALL=C
      if (( ${#val} < 1 || ${#val} > 32 )) || [[ $val =~ [[:cntrl:]] ]]; then
        VALIDATE_REASON="must be 1 to 32 bytes and contain no control characters"
        return 1
      fi
      ;;
    WIFI_SECURITY)
      if [[ $val != open && $val != wpa-psk ]]; then
        VALIDATE_REASON="must be open or wpa-psk"
        return 1
      fi
      ;;
    WIFI_PASSWORD)
      local LC_ALL=C
      if ! [[ $val =~ ^[[:print:]]{8,63}$ || $val =~ ^[A-Fa-f0-9]{64}$ ]]; then
        VALIDATE_REASON="must be 8 to 63 printable ASCII characters or a 64-digit hexadecimal PSK"
        return 1
      fi
      ;;
    WIFI_HIDDEN)
      if [[ $val != yes && $val != no ]]; then
        VALIDATE_REASON="must be yes or no"
        return 1
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
  for key in HOSTNAME USER_SHELL TIMEZONE LOCALE KEYMAP MIRROR SWAP CHEZMOI_REPO CHEZMOI_MODE \
             WIFI_SECURITY WIFI_HIDDEN \
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

  if [[ -n $WIFI_SSID ]]; then
    if ! validate_one WIFI_SSID "$WIFI_SSID"; then
      echo "Invalid value for WIFI_SSID: $VALIDATE_REASON" >&2
      exit 2
    fi
    if [[ $WIFI_SECURITY == wpa-psk ]]; then
      if [[ ! -v WIFI_PASSWORD ]] || ! validate_one WIFI_PASSWORD "$WIFI_PASSWORD"; then
        echo "WIFI_PASSWORD is required for WPA-Personal Wi-Fi and must be a valid passphrase or PSK." >&2
        exit 2
      fi
    elif [[ -v WIFI_PASSWORD ]]; then
      echo "WIFI_PASSWORD must be omitted when WIFI_SECURITY=open." >&2
      exit 2
    fi
  elif [[ -v WIFI_PASSWORD ]] || is_config_set WIFI_SECURITY || is_config_set WIFI_HIDDEN; then
    echo "WIFI_SSID is required when Wi-Fi settings are supplied." >&2
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
  local dtype sizeb read_only device_name holders
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
  read_only=$(lsblk -dno RO "$TARGET_DISK" 2>/dev/null || echo 1)
  if [[ $read_only != 0 ]]; then
    echo "Target disk is read-only." >&2
    exit 2
  fi
  while IFS= read -r device_name; do
    [[ -n $device_name ]] || continue
    holders="/sys/class/block/${device_name##*/}/holders"
    if [[ -d $holders ]] && compgen -G "$holders/*" >/dev/null; then
      echo "Target disk is in use by another block device (holder: $device_name)." >&2
      exit 2
    fi
  done < <(lsblk -nrpo NAME "$TARGET_DISK")
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
  if [[ ! -d /mnt ]]; then
    echo "Mount directory /mnt is missing or is not a directory." >&2
    exit 3
  fi
  if ! command -v findmnt >/dev/null 2>&1; then
    echo "Required tool not found on the live system: findmnt" >&2
    exit 3
  fi
  if (( RESUME_MODE == 0 && REPAIR_MODE == 0 )); then
    if findmnt -rn -o TARGET | awk '$0 == "/mnt" || index($0, "/mnt/") == 1 { found=1 } END { exit !found }'; then
      echo "The /mnt tree already contains a mount; unmount it before installing." >&2
      exit 3
    fi
    if [[ -n $(find /mnt -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      echo "The /mnt directory is not empty; move its contents before installing." >&2
      exit 3
    fi
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
  local secureboot_status
  secureboot_status=$(secure_boot_status /sys/firmware/efi/efivars)
  if [[ $secureboot_status == enabled ]]; then
    echo "Secure Boot is enabled. Disable Secure Boot in firmware; signed boot is not supported." >&2
    exit 3
  elif [[ $secureboot_status == unknown ]]; then
    echo "Warning: Secure Boot state could not be read; boot compatibility will be checked after GRUB installation." >&2
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
  require_tool findmnt --version
  require_tool od --version
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

secure_boot_status() {  # optional argument: efivarfs directory (for tests)
  local efivars=${1:-/sys/firmware/efi/efivars} variable value
  for variable in "$efivars"/SecureBoot-*; do
    [[ -f $variable && -r $variable ]] || continue
    if ! value=$(od -An -j4 -N1 -tu1 "$variable" 2>/dev/null | tr -d '[:space:]'); then
      printf 'unknown\n'
      return 0
    fi
    case $value in
      1) printf 'enabled\n' ;;
      0) printf 'disabled\n' ;;
      *) printf 'unknown\n' ;;
    esac
    return 0
  done
  printf 'unknown\n'
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
           alsa-utils void-repo-nonfree wayfire wf-shell kitty greetd tuigreet \
           dejavu-fonts-ttf adwaita-icon-theme \
           chezmoi git curl wget openssh gnupg age unzip xz tar rsync python3 \
           base-devel nano; do
    pkg_add "$p"
  done

  SV_FATAL=(dbus polkitd NetworkManager chronyd acpid grub-btrfs greetd)
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

  PROBE_DIR=$(mktemp -d /tmp/void-installer-probe.XXXXXX)
  PROBE_ROOT="$PROBE_DIR/root"
  PROBE_CONF="$PROBE_DIR/conf"
  mkdir -p "$PROBE_ROOT/var/db/xbps/keys" "$PROBE_CONF"
  cp /var/db/xbps/keys/* "$PROBE_ROOT/var/db/xbps/keys/"
  if ! XBPS_ARCH=x86_64 xbps-install -i -C "$PROBE_CONF" -r "$PROBE_ROOT" \
      --repository="$MIRROR/current" --repository="$MIRROR/current/nonfree" -S -y; then
    echo "Could not synchronize the isolated package-probe cache." >&2
    exit 3
  fi
  if ! probe_query base-system >/dev/null 2>&1; then
    echo "Repository $MIRROR/current is not readable by this xbps (layout mismatch or mirror problem). Use a newer live ISO or another MIRROR." >&2
    exit 3
  fi

  # Query the synchronized isolated root without -M so XBPS reuses the local
  # repodata rather than fetching it once per package.
  for pkg in "${PKGS_ALL[@]}"; do
    if ! probe_query "$pkg" >/dev/null; then
      echo "Package not found in repository: $pkg" >&2
      exit 3
    fi
  done

  if ! probe_query -f elogind | grep -F "usr/share/dbus-1/system-services/org.freedesktop.login1.service" >/dev/null; then
    echo "Package elogind does not provide the org.freedesktop.login1 D-Bus activation file." >&2
    exit 3
  fi

  local -a pairs=(dbus:dbus polkit:polkitd \
                  chrony:chronyd acpid:acpid greetd:greetd)
  if [[ $SWAP == zram ]]; then
    pairs+=(zramen:zramen)
  fi
  for svc in "${pairs[@]}"; do
    pkg=${svc%%:*}
    svc=${svc##*:}
    if probe_query -f "$pkg" | grep -q "etc/sv/$svc"; then
      continue
    fi
    echo "Package $pkg does not provide service $svc." >&2
    exit 3
  done

  # NetworkManager: ship our own runit service if the package does not
  # provide one (verified on some Void releases/repos where the service
  # directory is absent from the binary package).
  if probe_query -f NetworkManager | grep -q "etc/sv/NetworkManager"; then
    NETWORKMANAGER_OWN=0
  else
    NETWORKMANAGER_OWN=1
  fi

  # The grub-btrfs runit service ships with the main grub-btrfs package
  # (grub-btrfs-runit is an empty transitional package). If neither ships a
  # grub-btrfs service directory we provide our own run script instead of
  # failing (spec 10.1).
  if probe_query -f grub-btrfs | grep -q "etc/sv/grub-btrfs"; then
    GRUB_BTRFS_OWN=0
  else
    GRUB_BTRFS_OWN=1
  fi
  cleanup_probe_cache
}

probe_query() {
  xbps-query -i -C "$PROBE_CONF" -r "$PROBE_ROOT" -R \
    --repository="$MIRROR/current" --repository="$MIRROR/current/nonfree" "$@"
}

cleanup_probe_cache() {
  if [[ -n $PROBE_DIR && -d $PROBE_DIR ]]; then
    rm -rf -- "$PROBE_DIR"
  fi
  PROBE_DIR=""
  PROBE_ROOT=""
  PROBE_CONF=""
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

prompt_wifi_password() {
  local p1 p2
  while true; do
    if ! p1=$(dialog --clear --title "WIFI_PASSWORD" --passwordbox \
        "Wi-Fi password for $WIFI_SSID" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if ! p2=$(dialog --clear --title "WIFI_PASSWORD" --passwordbox \
        "Repeat Wi-Fi password" 10 70 3>&1 1>&2 2>&3); then
      exit 4
    fi
    if [[ $p1 != "$p2" ]]; then
      dialog --msgbox "Wi-Fi passwords do not match." 10 70 || exit 4
      continue
    fi
    WIFI_PASSWORD=$p1
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
  if [[ -n $CHEZMOI_REPO ]] && ! is_config_set CHEZMOI_MODE; then
    prompt_menu CHEZMOI_MODE "DOTFILES SETUP" "When should chezmoi apply this repository?" \
      first-login "First interactive login (recommended)" \
      install "During installation (requires sudo for scripts)"
  fi
  if ! is_config_set WIFI_SSID; then
    prompt_menu WIFI_SETUP "WI-FI NETWORK" "Save one Wi-Fi network for the installed system?" \
      no "No, configure networking after installation" \
      yes "Yes, save a network for first boot"
  fi
  if [[ $WIFI_SETUP == yes ]]; then
    if ! is_config_set WIFI_SSID; then
      prompt_value WIFI_SSID "Wi-Fi network name (SSID)"
    fi
    if ! is_config_set WIFI_SECURITY; then
      prompt_menu WIFI_SECURITY "WI-FI SECURITY" "Select the network security type" \
        wpa-psk "WPA-Personal" open "Open network"
    fi
    if [[ $WIFI_SECURITY == wpa-psk ]] && ! is_config_set WIFI_PASSWORD; then
      prompt_wifi_password
    fi
    if ! is_config_set WIFI_HIDDEN; then
      prompt_menu WIFI_HIDDEN "HIDDEN WI-FI" "Does this network hide its name?" \
        no "No" yes "Yes"
    fi
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
  if [[ -n $CHEZMOI_REPO ]]; then
    printf '  %-12s %s\n' "Dotfiles run:" "$CHEZMOI_MODE"
  fi
  printf '  %-12s %s\n' "Wi-Fi:" "${WIFI_SSID:-none}"
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

mount_owned() {  # $1 = mountpoint; remaining args are passed to mount
  local target=$1
  shift
  mount "$@"
  record_owned_mount "$target"
}

record_owned_mount() {  # $1 = mountpoint already mounted by this installer
  local target=$1 identity source fstype
  identity=$(findmnt -rn -o TARGET,SOURCE,FSTYPE | awk -v target="$target" '$1 == target { print $2 "|" $3; found=1; exit } END { if (!found) exit 1 }')
  IFS='|' read -r source fstype <<< "$identity"
  [[ -n $source && -n $fstype ]] || { echo "Could not record mount identity for $target." >&2; return 1; }
  INSTALL_MOUNTS+=("$target|$source|$fstype")
}

record_owned_mount_tree() {  # $1 = recursive bind root; records nested binds too
  local root=$1 target source fstype
  while read -r target source fstype; do
    [[ $target == "$root" || $target == "$root/"* ]] || continue
    [[ $target == "$root" ]] && continue
    INSTALL_MOUNTS+=("$target|$source|$fstype")
  done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE)
}

unmount_owned() {
  local entry target expected_source expected_fstype actual_source actual_fstype index
  for (( index=${#INSTALL_MOUNTS[@]} - 1; index >= 0; index-- )); do
    entry=${INSTALL_MOUNTS[index]}
    IFS='|' read -r target expected_source expected_fstype <<< "$entry"
    if ! findmnt -rn -o TARGET | awk -v target="$target" '$0 == target { found=1 } END { exit !found }'; then
      unset 'INSTALL_MOUNTS[index]'
      continue
    fi
    identity=$(findmnt -rn -o TARGET,SOURCE,FSTYPE | awk -v target="$target" '$1 == target { print $2 "|" $3; found=1; exit } END { if (!found) exit 1 }' || true)
    IFS='|' read -r actual_source actual_fstype <<< "$identity"
    if [[ $actual_source != "$expected_source" || $actual_fstype != "$expected_fstype" ]]; then
      echo "Leaving mount at $target in place because its identity changed." >&2
      continue
    fi
    if ! umount "$target"; then
      echo "Could not unmount installer-owned mount at $target." >&2
      continue
    fi
    unset 'INSTALL_MOUNTS[index]'
  done
}

partition_disk() {
  # Targeted swapoff: only deactivate swap on the target disk.
  # swapoff -a would take down unrelated system swap (other disks, zram).
  # Match partitions of TARGET_DISK: /dev/sdaN, /dev/nvme0n1pN, /dev/mmcblk0pN, etc.
  local swdev
  while IFS= read -r swdev; do
    case $swdev in
      "$TARGET_DISK"[0-9]*|"$TARGET_DISK"p[0-9]*)
        if ! swapoff "$swdev"; then
          echo "Could not deactivate target-disk swap device $swdev." >&2
          return 1
        fi ;;
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
  mount_owned /mnt "$(part 2)" /mnt             # top level (subvolid 5)
  for sv in @ @home @snapshots @var_log @var_cache_xbps @var_tmp; do
    btrfs subvolume create "/mnt/$sv"
  done
  unmount_owned

  mount_owned /mnt -o "$BTRFS_OPTS,subvol=@" "$(part 2)" /mnt
  mkdir -p /mnt/{home,.snapshots,var/log,var/cache/xbps,var/tmp,boot/efi}
  mount_owned /mnt/home -o "$BTRFS_OPTS,subvol=@home" "$(part 2)" /mnt/home
  mount_owned /mnt/var/log -o "$BTRFS_OPTS,subvol=@var_log" "$(part 2)" /mnt/var/log
  mount_owned /mnt/var/cache/xbps -o "$BTRFS_OPTS,subvol=@var_cache_xbps" "$(part 2)" /mnt/var/cache/xbps
  mount_owned /mnt/var/tmp -o "$BTRFS_OPTS,subvol=@var_tmp" "$(part 2)" /mnt/var/tmp
  # @snapshots is deliberately not mounted yet: snapper creates a nested
  # .snapshots subvolume first, which setup_snapper replaces (spec 10.4/10.8).
  mount_owned /mnt/boot/efi -o umask=0077 "$(part 1)" /mnt/boot/efi
}

write_install_state() {
  local tmp key
  [[ -n $INSTALL_STATE ]] || return 0
  tmp=$(mktemp "${INSTALL_STATE}.tmp.XXXXXX")
  {
    printf 'FORMAT=1\nVERSION=%s\nROOT_UUID=%s\nESP_UUID=%s\nTARGET_DISK=%s\nLAST_COMPLETED_STEP=%s\nLAST_COMPLETED_CHECKPOINT=%s\nINSTALL_STATUS=%s\n' \
      "$INSTALLER_VERSION" "$ROOT_UUID" "$ESP_UUID" "$TARGET_DISK" "$INSTALL_STATE_STEP" \
      "${INSTALL_STATE_CHECKPOINT:-none}" "${INSTALL_STATUS:-active}"
    for key in HOSTNAME USERNAME USER_SHELL TIMEZONE LOCALE KEYMAP MIRROR SWAP CHEZMOI_MODE \
               WIFI_SSID WIFI_SECURITY WIFI_HIDDEN \
               CHEZMOI_REPO EXTRA_PACKAGES HW_CHASSIS HW_TOUCH HW_FINGERPRINT HW_BLUETOOTH; do
      printf '%s=%s\n' "$key" "${!key-}"
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE"
}

initialize_install_state() {
  local state_dir=/mnt/var/lib/void-installer
  mkdir -p "$state_dir"
  chmod 0700 "$state_dir"
  INSTALL_STATE="$state_dir/state"
  if [[ -e $INSTALL_STATE || -L $INSTALL_STATE ]]; then
    echo "Installer state path already exists; refusing to overwrite it." >&2
    return 1
  fi
  INSTALL_STATE_STEP=10
  INSTALL_STATE_CHECKPOINT="filesystems-mounted"
  INSTALL_STATUS="active"
  write_install_state
}

read_install_state() {
  local file=$1 line key val line_number=0
  local -A seen=()
  [[ -f $file && ! -L $file && -r $file ]] || { echo "Installer state is missing or unsafe." >&2; return 1; }
  [[ -d ${file%/*} && ! -L ${file%/*} && $(stat -c %a "${file%/*}") == 700 && $(stat -c %u "${file%/*}") == 0 ]] || {
    echo "Installer state directory is unsafe." >&2; return 1;
  }
  [[ $(stat -c %a "$file") == 600 && $(stat -c %u "$file") == 0 ]] || { echo "Installer state permissions must be root-owned 0600." >&2; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { echo "Malformed installer state at line $line_number." >&2; return 1; }
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    [[ ! ${seen[$key]+yes} ]] || { echo "Duplicate installer state key $key." >&2; return 1; }
    seen[$key]=1
    case $key in
      FORMAT|VERSION|ROOT_UUID|ESP_UUID|TARGET_DISK|LAST_COMPLETED_STEP|LAST_COMPLETED_CHECKPOINT|INSTALL_STATUS|\
      HOSTNAME|USERNAME|USER_SHELL|TIMEZONE|LOCALE|KEYMAP|MIRROR|SWAP|CHEZMOI_MODE|\
      WIFI_SSID|WIFI_SECURITY|WIFI_HIDDEN|CHEZMOI_REPO|EXTRA_PACKAGES|HW_CHASSIS|HW_TOUCH|HW_FINGERPRINT|HW_BLUETOOTH) ;;
      *) echo "Unsupported key in installer state: $key." >&2; return 1 ;;
    esac
    printf -v "$key" '%s' "$val"
  done < "$file"
  for key in FORMAT VERSION ROOT_UUID ESP_UUID TARGET_DISK LAST_COMPLETED_STEP LAST_COMPLETED_CHECKPOINT INSTALL_STATUS \
              HOSTNAME USERNAME USER_SHELL TIMEZONE LOCALE KEYMAP MIRROR SWAP CHEZMOI_MODE WIFI_SSID WIFI_SECURITY \
              WIFI_HIDDEN CHEZMOI_REPO EXTRA_PACKAGES HW_CHASSIS HW_TOUCH HW_FINGERPRINT HW_BLUETOOTH; do
    [[ ${seen[$key]+yes} ]] || { echo "Installer state is missing required key $key." >&2; return 1; }
  done
  # VERSION is assigned by the validated state-key reader above.
  # shellcheck disable=SC2153
  [[ $FORMAT == 1 && $VERSION == "$INSTALLER_VERSION" ]] || { echo "Installer state format/version does not match this installer." >&2; return 1; }
  if [[ ! $LAST_COMPLETED_STEP =~ ^[0-9]+$ ]] || (( LAST_COMPLETED_STEP < 10 || LAST_COMPLETED_STEP >= INSTALLER_TOTAL_STEPS )); then
    echo "Installer state checkpoint is invalid or already complete." >&2; return 1;
  fi
  [[ $INSTALL_STATUS == active ]] || { echo "Installer state is not marked active." >&2; return 1; }
  case "$LAST_COMPLETED_STEP:$LAST_COMPLETED_CHECKPOINT" in
    10:filesystems-mounted|11:bootstrap-prepared|12:packages-installed|13:system-configured|14:snapper-configured|15:bootloader-configured|16:services-enabled|17:accounts-configured|18:desktop-configured|19:chezmoi-hook-configured|20:chezmoi-applied|21:wrappers-installed|22:initial-snapshot|23:validated) ;;
    *) echo "Installer checkpoint number and name do not match." >&2; return 1 ;;
  esac
  [[ $ROOT_UUID =~ ^[[:alnum:]-]+$ && $ESP_UUID =~ ^[[:alnum:]-]+$ ]] || { echo "Invalid device UUID in installer state." >&2; return 1; }
  [[ $TARGET_DISK == /dev/* && $TARGET_DISK != *[[:space:]]* ]] || { echo "Invalid target disk in installer state." >&2; return 1; }
  INSTALL_STATE_STEP=$LAST_COMPLETED_STEP
  INSTALL_STATE_CHECKPOINT=$LAST_COMPLETED_CHECKPOINT
}

identify_existing_devices() {
  local requested root_type parent part type uuid
  requested=$(readlink -f -- "$ROOT_PARTITION") || { echo "Cannot resolve root partition $ROOT_PARTITION." >&2; return 1; }
  [[ -b $requested ]] || { echo "Root partition must be a block device." >&2; return 1; }
  root_type=$(lsblk -dnro TYPE "$requested")
  [[ $root_type == part && $(blkid -s TYPE -o value "$requested") == btrfs ]] || {
    echo "Root device must be a Btrfs partition." >&2; return 1;
  }
  parent=$(lsblk -dnro PKNAME "$requested")
  [[ -n $parent ]] || { echo "Could not identify the whole disk containing $requested." >&2; return 1; }
  TARGET_DISK=$(readlink -f "/dev/$parent")
  [[ -b $TARGET_DISK && $(lsblk -dnro TYPE "$TARGET_DISK") == disk ]] || { echo "Invalid parent disk for $requested." >&2; return 1; }
  if lsblk -nrpo MOUNTPOINT "$TARGET_DISK" | grep -q '[^[:space:]]'; then
    echo "A partition on $TARGET_DISK is already mounted; unmount it before resume or repair." >&2
    return 1
  fi
  if lsblk -nrpo NAME,HOLDERS "$TARGET_DISK" | awk 'NF > 1 && $2 != "" { found=1 } END { exit !found }'; then
    echo "A partition on $TARGET_DISK has active block-device holders." >&2
    return 1
  fi
  ROOT_PARTITION=$requested
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
  ESP_PARTITION=""
  while read -r part type; do
    [[ ${type,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] || continue
    uuid=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
    if [[ -n ${ESP_UUID:-} && $uuid == "$ESP_UUID" ]] || [[ -z ${ESP_UUID:-} ]]; then
      ESP_PARTITION=$part; ESP_UUID=$uuid; break
    fi
  done < <(lsblk -nrpo NAME,PARTTYPE "$TARGET_DISK")
  [[ -n $ESP_PARTITION && -n $ESP_UUID ]] || { echo "Could not identify the expected EFI partition on $TARGET_DISK." >&2; return 1; }
  if [[ -n ${EXPECTED_ROOT_UUID:-} && $ROOT_UUID != "$EXPECTED_ROOT_UUID" ]]; then
    echo "Root partition UUID does not match the saved installer state." >&2; return 1
  fi
  if [[ -n ${EXPECTED_ESP_UUID:-} && $ESP_UUID != "$EXPECTED_ESP_UUID" ]]; then
    echo "EFI partition UUID does not match the saved installer state." >&2; return 1
  fi
  if [[ -n ${EXPECTED_TARGET_DISK:-} && $TARGET_DISK != "$EXPECTED_TARGET_DISK" ]]; then
    echo "Parent disk does not match the saved installer state." >&2; return 1
  fi
}

mount_existing_layout() {
  local sv
  if findmnt -rn -o TARGET | awk '$0 == "/mnt" { found=1 } END { exit !found }'; then
    local owned=0 entry
    for entry in "${INSTALL_MOUNTS[@]}"; do [[ $entry == /mnt\|* ]] && owned=1; done
    if (( owned == 0 )); then echo "The /mnt tree is already mounted by another process." >&2; return 1; fi
  else
    if findmnt -rn -o TARGET | awk 'index($0, "/mnt/") == 1 { found=1 } END { exit !found }' \
        || [[ -n $(find /mnt -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      echo "The /mnt tree must be empty and unmounted before resume or repair." >&2
      return 1
    fi
    mount_owned /mnt -o "$BTRFS_OPTS,subvol=@" "$ROOT_PARTITION" /mnt
  fi
  mkdir -p /mnt/{home,.snapshots,var/log,var/cache/xbps,var/tmp,boot/efi}
  for sv in @home @snapshots @var_log @var_cache_xbps @var_tmp; do
    if [[ $sv == @snapshots ]] && (( RESUME_MODE == 1 && INSTALL_STATE_STEP < 14 )); then
      continue
    fi
    case $sv in
      @home) mount_owned /mnt/home -o "$BTRFS_OPTS,subvol=$sv" "$ROOT_PARTITION" /mnt/home ;;
      @snapshots) mount_owned /mnt/.snapshots -o "$BTRFS_OPTS,subvol=$sv" "$ROOT_PARTITION" /mnt/.snapshots ;;
      @var_log) mount_owned /mnt/var/log -o "$BTRFS_OPTS,subvol=$sv" "$ROOT_PARTITION" /mnt/var/log ;;
      @var_cache_xbps) mount_owned /mnt/var/cache/xbps -o "$BTRFS_OPTS,subvol=$sv" "$ROOT_PARTITION" /mnt/var/cache/xbps ;;
      @var_tmp) mount_owned /mnt/var/tmp -o "$BTRFS_OPTS,subvol=$sv" "$ROOT_PARTITION" /mnt/var/tmp ;;
    esac
  done
  mount_owned /mnt/boot/efi -o umask=0077 "$ESP_PARTITION" /mnt/boot/efi
}

preserve_install_log() {
  local entry target expected_source expected_fstype identity source fstype log_dir
  [[ -n $INSTALLER_LOG && -f $INSTALLER_LOG ]] || return 0
  for entry in "${INSTALL_MOUNTS[@]}"; do
    IFS='|' read -r target expected_source expected_fstype <<< "$entry"
    [[ $target == /mnt ]] || continue
    identity=$(findmnt -rn -o TARGET,SOURCE,FSTYPE | awk -v target="$target" '$1 == target { print $2 "|" $3; found=1; exit } END { if (!found) exit 1 }' || true)
    IFS='|' read -r source fstype <<< "$identity"
    [[ $source == "$expected_source" && $fstype == "$expected_fstype" ]] || return 0
    log_dir=/mnt/var/log/void-installer
    mkdir -p "$log_dir"
    chmod 0700 "$log_dir"
    install -m 0600 "$INSTALLER_LOG" "$log_dir/${INSTALLER_LOG##*/}"
    return 0
  done
}

# --------------------------------------------------------------------------
# Bootstrap (spec sections 10.5, 10.6)
# --------------------------------------------------------------------------

bootstrap_system() {
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
      mount_target_bindings
      cp /etc/resolv.conf /mnt/etc/resolv.conf
      ;;
  esac
}

mount_target_bindings() {
  local d
  for d in dev proc sys; do
    if ! findmnt -rn -o TARGET | awk -v target="/mnt/$d" '$0 == target { found=1 } END { exit !found }'; then
      mount_owned "/mnt/$d" --rbind "/$d" "/mnt/$d"
      record_owned_mount_tree "/mnt/$d"
      mount --make-rslave "/mnt/$d"
    fi
  done
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
  write_wifi_profile /mnt
}

escape_nm_keyfile_value() {
  local value=${1//\\/\\\\}
  if [[ $value == ' '* ]]; then
    value="\\s${value:1}"
  fi
  if [[ $value == *' ' ]]; then
    value="${value:0:${#value}-1}\\s"
  fi
  printf '%s' "$value"
}

write_wifi_profile() {  # $1 = target root (defaults to /mnt)
  local target=${1:-/mnt} directory file ssid password
  [[ -n $WIFI_SSID ]] || return 0
  directory="$target/etc/NetworkManager/system-connections"
  file="$directory/installer-wifi.nmconnection"
  mkdir -p "$directory"
  chmod 0700 "$directory"
  ssid=$(escape_nm_keyfile_value "$WIFI_SSID")
  {
    cat <<'NM_EOF'
[connection]
id=Installer Wi-Fi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
NM_EOF
    printf 'ssid=%s\n' "$ssid"
    if [[ $WIFI_HIDDEN == yes ]]; then
      printf 'hidden=true\n'
    fi
    if [[ $WIFI_SECURITY == wpa-psk ]]; then
      password=$(escape_nm_keyfile_value "$WIFI_PASSWORD")
      cat <<'NM_EOF'

[wifi-security]
key-mgmt=wpa-psk
NM_EOF
      printf 'psk=%s\n' "$password"
    fi
    cat <<'NM_EOF'

[ipv4]
method=auto

[ipv6]
method=auto
NM_EOF
  } > "$file"
  chown root:root "$file"
  chmod 0600 "$file"
  echo "Saved the Wi-Fi profile for first boot with root-only permissions."
}

# --------------------------------------------------------------------------
# snapper / GRUB / services / user (spec sections 10.8-10.11)
# --------------------------------------------------------------------------

setup_snapper() {
  if [[ ! -f /mnt/etc/snapper/configs/root ]]; then
    chroot /mnt /bin/bash -s <<'CHROOT_EOF'
set -eu
# /.snapshots exists as an empty directory (created by mount_layout); snapper
# needs the path absent to create its nested subvolume, which is replaced
# right after with the @snapshots subvolume via fstab.
rmdir /.snapshots 2>/dev/null || true
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
CHROOT_EOF
  fi
  if ! findmnt -rn -o TARGET | awk '$0 == "/mnt/.snapshots" { found=1 } END { exit !found }'; then
    mount_owned /mnt/.snapshots -o "$BTRFS_OPTS,subvol=@snapshots" "${ROOT_PARTITION:-$(part 2)}" /mnt/.snapshots
  fi
  chroot /mnt /bin/bash -s <<'CHROOT_EOF'
set -eu
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
  install_grub_bootloaders
  chroot /mnt xbps-reconfigure -fa
  set_grub_default GRUB_CMDLINE_LINUX_DEFAULT "loglevel=4"
  set_grub_default GRUB_DISABLE_OS_PROBER "true"
  set_grub_default GRUB_TIMEOUT "3"
  chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

install_grub_bootloaders() {
  local named_rc=0
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void || named_rc=$?
  if (( named_rc != 0 )); then
    echo "Warning: could not create the named UEFI boot entry; installing the EFI fallback path." >&2
  fi
  chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
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

validate_elogind_activation() {
  local target_root=${1:-/mnt}
  local activation_file="$target_root/usr/share/dbus-1/system-services/org.freedesktop.login1.service"
  if [[ ! -s $activation_file ]]; then
    echo "Elogind's org.freedesktop.login1 D-Bus activation file is missing from the target." >&2
    return 1
  fi
}

validate_enabled_services() {
  local target_root=${1:-/mnt} svc
  for svc in "${SV_FATAL[@]}"; do
    if [[ ! -L $target_root/etc/runit/runsvdir/default/$svc || ! -d $target_root/etc/sv/$svc ]]; then
      echo "Required runit service $svc is not enabled in the installed system." >&2
      return 1
    fi
  done
}

create_user() {
  local account_status status_name status_code _status_details
  if ! chroot /mnt id -u "$USERNAME" >/dev/null 2>&1; then
    chroot /mnt useradd -m -s "$USER_SHELL" -G wheel,audio,video,input "$USERNAME"
  fi
  # Passwords are passed on stdin only: never on disk outside /etc/shadow,
  # never in the process list, never in the chroot environment.
  account_status=$(LC_ALL=C chroot /mnt passwd -S "$USERNAME")
  read -r status_name status_code _status_details <<< "$account_status"
  if [[ $status_code != P ]]; then
    if [[ -v USER_PASSWORD_HASH ]]; then
      printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD_HASH" | chroot /mnt chpasswd -e
    else
    # An explicit crypt method bypasses PAM: Void's shipped chpasswd PAM
    # password stack can permit the operation without updating the hash.
      printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot /mnt chpasswd -c SHA512
    fi
  fi

  # Set an independent root password; root remains available at the console
  # as a recovery account if the regular user cannot authenticate.
  account_status=$(LC_ALL=C chroot /mnt passwd -S root)
  read -r status_name status_code _status_details <<< "$account_status"
  if [[ $status_code != P ]]; then
    if [[ -v ROOT_PASSWORD_HASH ]]; then
      printf 'root:%s\n' "$ROOT_PASSWORD_HASH" | chroot /mnt chpasswd -e
    else
      printf 'root:%s\n' "$ROOT_PASSWORD" | chroot /mnt chpasswd -c SHA512
    fi
  fi

  # Catch incomplete account setup before reporting a successful install.
  account_status=$(LC_ALL=C chroot /mnt passwd -S "$USERNAME")
  read -r status_name status_code _status_details <<< "$account_status"
  if [[ $status_name != "$USERNAME" || $status_code != P ]]; then
    echo "User account $USERNAME does not have an active password after setup (status: ${status_code:-unknown})." >&2
    exit 1
  fi
  account_status=$(LC_ALL=C chroot /mnt passwd -S root)
  read -r status_name status_code _status_details <<< "$account_status"
  if [[ $status_name != root || $status_code != P ]]; then
    echo "Root account does not have an active password after setup (status: ${status_code:-unknown})." >&2
    exit 1
  fi
}

write_desktop_user_file() {  # $1 = target root, $2 = path inside target; stdin = contents
  local target=$1 path=$2 tmp
  if [[ -L $target$path || ( -e $target$path && ! -f $target$path ) ]]; then
    echo "Unsafe desktop configuration destination: $path" >&2
    return 1
  fi
  if [[ -f $target$path ]]; then
    cat >/dev/null
    return 0
  fi
  tmp=$(mktemp "$target$path.tmp.XXXXXX")
  cat > "$tmp"
  chmod 0644 "$tmp"
  chroot "$target" chown "$USERNAME:$USERNAME" "${tmp#"$target"}"
  mv -f "$tmp" "$target$path"
}

configure_desktop() {  # optional target root for regression fixtures
  local target=${1:-/mnt} config path panel_widgets="tray network clock"
  if [[ ${HW_CHASSIS_RESULT:-} == laptop ]]; then
    panel_widgets="tray network battery clock"
  fi
  config="$target/home/$USERNAME/.config"
  derive_desktop_keymap "$KEYMAP"
  for path in "$target/home/$USERNAME" "$config" "$target/etc/void-installer"; do
    if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
      echo "Unsafe desktop configuration directory." >&2
      return 1
    fi
  done
  mkdir -p "$config" "$target/etc/void-installer"
  chroot "$target" chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
  write_desktop_user_file "$target" "/home/$USERNAME/.config/wayfire.ini" <<DESKTOP_EOF
# void-installer Wayfire baseline; user dotfiles may replace this file.
[core]
plugins = autostart command decoration foreign-toplevel grid gtk-shell move place resize switcher vswitch wayfire-shell wm-actions
close_top_view = <super> KEY_Q | <alt> KEY_F4
vwidth = 3
vheight = 1

[input]
xkb_layout = $XKB_LAYOUT
xkb_variant = $XKB_VARIANT
xkb_model = $XKB_MODEL

[autostart]
autostart_wf_shell = true
0_env = dbus-update-activation-environment WAYLAND_DISPLAY DISPLAY XAUTHORITY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE

[command]
binding_terminal = <super> KEY_ENTER
command_terminal = kitty
binding_logout = <super> KEY_ESC
command_logout = wayland-logout

[move]
activate = <super> BTN_LEFT

[resize]
activate = <super> BTN_RIGHT

[switcher]
next_view = <alt> KEY_TAB
prev_view = <alt> <shift> KEY_TAB

[grid]
slot_l = <super> KEY_LEFT
slot_r = <super> KEY_RIGHT
slot_t = <super> KEY_UP
restore = <super> KEY_DOWN

[vswitch]
binding_left = <ctrl> <super> KEY_LEFT
binding_right = <ctrl> <super> KEY_RIGHT
with_win_left = <ctrl> <super> <shift> KEY_LEFT
with_win_right = <ctrl> <super> <shift> KEY_RIGHT

[wayfire-shell]
toggle_menu = <super>
DESKTOP_EOF
  write_desktop_user_file "$target" "/home/$USERNAME/.config/wf-shell.ini" <<SHELL_CONFIG_EOF
[panel]
widgets_left = menu spacing4 launchers window-list
widgets_center = none
widgets_right = $panel_widgets
position = top
autohide = false
minimal_height = 28
launcher_terminal = kitty.desktop
menu_logout_command = wayland-logout
clock_format = %a %H:%M

[background]
image = /usr/share/wf-shell/backgrounds/wallpaper.jpg
fill_mode = fill_and_crop
SHELL_CONFIG_EOF
  local marker="$target/etc/void-installer/desktop.conf"
  [[ ! -L $marker && ( ! -e $marker || -f $marker ) ]] || {
    echo "Unsafe desktop installation marker." >&2; return 1;
  }
  printf 'USERNAME=%s\nKEYMAP=%s\n' "$USERNAME" "$KEYMAP" > "$marker"
  chmod 0644 "$marker"
  configure_greetd "$target"
  echo "Configured Wayfire and wf-shell; desktop keyboard: $XKB_LAYOUT ${XKB_VARIANT:-default}."
}

configure_greetd() {
  local target=${1:-/mnt}
  chroot "$target" python3 - <<'GREETD_CONFIG_EOF'
import json
import os
import pathlib
import pwd
import re
import tempfile
import tomllib

config = pathlib.Path("/etc/greetd/config.toml")
cache = pathlib.Path("/var/cache/tuigreet")
default = pathlib.Path("/etc/runit/runsvdir/default")
marker = pathlib.Path("/etc/void-installer/greetd.conf")
for path in (config.parent, cache, marker.parent):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise SystemExit("Unsafe greetd configuration directory.")
for path in (config, marker):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise SystemExit("Unsafe greetd configuration destination.")
original = config.read_text()
parsed = tomllib.loads(original)
greeter = parsed.get("default_session", {}).get("user")
if not isinstance(greeter, str) or not greeter:
    raise SystemExit("Packaged greetd configuration has no greeter account.")
account = pwd.getpwnam(greeter)
if account.pw_uid == 0:
    raise SystemExit("The greetd greeter account must not be root.")
if not (default / "agetty-tty1").is_symlink() or not (default / "agetty-tty1").is_dir():
    raise SystemExit("tty1 recovery console is missing; refusing to configure greetd.")
tty7 = default / "agetty-tty7"
if not tty7.is_symlink() and tty7.exists():
    raise SystemExit("tty7 has an unexpected service entry; refusing to remove it.")

command = "tuigreet --time --remember --remember-session --session-wrapper 'dbus-run-session --'"
# Change only the two managed keys; preserve the packaged user and comments.
section = ""
replaced = set()
lines = []
for line in original.splitlines(keepends=True):
    header = re.match(r"^\s*\[([a-z_]+)\]\s*(?:#.*)?$", line)
    if header:
        section = header[1]
    key = re.match(r"^\s*(vt|command)\s*=", line)
    if key and (section, key[1]) in {("terminal", "vt"), ("default_session", "command")}:
        value = "7" if key[1] == "vt" else json.dumps(command)
        line = f"{key[1]} = {value}\n"
        replaced.add((section, key[1]))
    lines.append(line)
if replaced != {("terminal", "vt"), ("default_session", "command")}:
    raise SystemExit("Packaged greetd configuration is missing its terminal/session keys.")
updated = "".join(lines)
check = tomllib.loads(updated)
if check["default_session"]["user"] != greeter:
    raise SystemExit("greetd greeter account changed unexpectedly.")
fd, name = tempfile.mkstemp(prefix=".config.", dir=config.parent)
try:
    with os.fdopen(fd, "w") as file:
        file.write(updated)
        os.fchmod(file.fileno(), 0o644)
    os.replace(name, config)
finally:
    if os.path.exists(name):
        os.unlink(name)
cache.mkdir(exist_ok=True)
os.chown(cache, account.pw_uid, account.pw_gid)
cache.chmod(0o755)
if tty7.is_symlink():
    tty7.unlink()
marker.write_text("VT=7\n")
marker.chmod(0o644)
GREETD_CONFIG_EOF
}

validate_greetd_installation() {
  local target=${1:-/mnt}
  [[ ! -L $target/etc/void-installer/greetd.conf ]] || { echo "Unsafe greetd marker." >&2; return 1; }
  [[ -f $target/etc/void-installer/greetd.conf ]] || return 0  # legacy repair
  chroot "$target" python3 - <<'GREETD_CHECK_EOF'
import os
import pathlib
import pwd
import shlex
import tomllib

with open("/etc/greetd/config.toml", "rb") as file:
    config = tomllib.load(file)
if config.get("terminal", {}).get("vt") != 7:
    raise SystemExit("greetd must use tty7 to preserve tty1 recovery.")
session = config.get("default_session", {})
account = pwd.getpwnam(session["user"])
if account.pw_uid == 0:
    raise SystemExit("greetd must use its packaged non-root greeter account.")
args = shlex.split(session.get("command", ""))
if args != ["tuigreet", "--time", "--remember", "--remember-session",
            "--session-wrapper", "dbus-run-session --"]:
    raise SystemExit("greetd is missing the configured tuigreet D-Bus session wrapper.")
cache = pathlib.Path("/var/cache/tuigreet")
if cache.is_symlink() or not cache.is_dir():
    raise SystemExit("tuigreet cache directory is missing or symlinked.")
info = cache.stat()
if (info.st_uid, info.st_gid, info.st_mode & 0o777) != (account.pw_uid, account.pw_gid, 0o755):
    raise SystemExit("tuigreet cache has incorrect ownership or permissions.")
default = pathlib.Path("/etc/runit/runsvdir/default")
for service in ("agetty-tty1", "greetd"):
    link = default / service
    if not link.is_symlink() or not link.is_dir() or link.resolve() != pathlib.Path("/etc/sv") / service:
        raise SystemExit(f"Required login service {service} is not enabled correctly.")
if (default / "agetty-tty7").exists() or (default / "agetty-tty7").is_symlink():
    raise SystemExit("agetty on tty7 conflicts with greetd.")
for path in ("/usr/bin/greetd", "/usr/bin/tuigreet", "/etc/sv/greetd/run"):
    if not os.access(path, os.X_OK):
        raise SystemExit(f"Required greetd executable is missing: {path}")
if not pathlib.Path("/etc/pam.d/greetd").is_file():
    raise SystemExit("Packaged greetd PAM configuration is missing.")
GREETD_CHECK_EOF
}

validate_desktop_installation() {
  local target=${1:-/mnt} key value desktop_user="" desktop_keymap="" program
  local marker="$target/etc/void-installer/desktop.conf"
  [[ ! -L $marker && ( ! -e $marker || -f $marker ) ]] || {
    echo "Unsafe desktop installation marker." >&2; return 1;
  }
  [[ -f $marker ]] || return 0
  while IFS='=' read -r key value; do
    case $key in USERNAME) desktop_user=$value ;; KEYMAP) desktop_keymap=$value ;; esac
  done < "$marker"
  [[ $desktop_user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $desktop_user != root ]] || {
    echo "Invalid desktop installation user." >&2; return 1;
  }
  derive_desktop_keymap "$desktop_keymap"
  for program in wayfire wf-panel wf-background wayland-logout kitty dbus-run-session fc-match; do
    [[ -x $target/usr/bin/$program ]] || { echo "Desktop executable $program is missing." >&2; return 1; }
  done
  chroot "$target" python3 - "$desktop_user" "$XKB_LAYOUT" "$XKB_VARIANT" "$XKB_MODEL" <<'DESKTOP_CHECK_EOF'
import configparser
import os
import pwd
import subprocess
import sys
import xml.etree.ElementTree as ET

user, layout, variant, model = sys.argv[1:]
rules = ET.parse("/usr/share/X11/xkb/rules/evdev.xml").getroot()
layouts = {item.findtext("configItem/name"): item for item in rules.findall("layoutList/layout")}
if layout not in layouts or (variant and variant not in {
        item.findtext("configItem/name") for item in layouts[layout].findall("variantList/variant")}):
    sys.exit("Derived desktop layout/variant is unavailable in the installed XKB rules.")
if model not in {item.findtext("configItem/name") for item in rules.findall("modelList/model")}:
    sys.exit("Derived desktop keyboard model is unavailable in the installed XKB rules.")
session = configparser.ConfigParser(interpolation=None)
session.read("/usr/share/wayland-sessions/wayfire.desktop")
if session.get("Desktop Entry", "Exec", fallback="") != "wayfire":
    sys.exit("Wayfire's native desktop session is missing or invalid.")
account = pwd.getpwnam(user)
uid = account.pw_uid
# Query the user's Fontconfig configuration without inheriting live-ISO overrides.
# File readability must also be checked with the user's privileges.
font_check = r'''
import os
import subprocess
import sys
for family in ("sans", "monospace"):
    match = subprocess.run(["/usr/bin/fc-match", "-f", "%{file}\\n%{scalable}\\n%{spacing}\\n", family],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    fields = match.stdout.splitlines()
    if (match.returncode != 0 or len(fields) < 2 or not fields[0]
            or not os.path.isfile(fields[0]) or not os.access(fields[0], os.R_OK)
            or fields[1].lower() != "true"
            or (family == "monospace" and (len(fields) < 3 or fields[2] != "100"))):
        sys.exit(f"No usable {family} font. Install dejavu-fonts-ttf and run fc-cache -f.")
'''
try:
    fonts = subprocess.run(
        [sys.executable, "-c", font_check],
        user=uid, group=account.pw_gid, extra_groups=os.getgrouplist(user, account.pw_gid),
        env={"PATH": "/usr/bin:/bin", "HOME": account.pw_dir,
             "XDG_CONFIG_HOME": os.path.join(account.pw_dir, ".config")},
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=70)
except (OSError, subprocess.TimeoutExpired) as error:
    sys.exit(f"Desktop font validation failed: {error}")
if fonts.returncode != 0:
    sys.exit(fonts.stderr.strip() or "Desktop font validation failed.")
for path in ("/usr/share/icons/Adwaita/index.theme",
             "/usr/share/icons/Adwaita/scalable/status/image-missing.svg"):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        sys.exit("Desktop icon assets are missing. Install adwaita-icon-theme.")
for name in ("wayfire.ini", "wf-shell.ini"):
    path = f"/home/{user}/.config/{name}"
    if os.path.islink(path) or not os.path.isfile(path) or os.stat(path).st_uid != uid:
        sys.exit("Desktop configuration is missing, symlinked, or not owned by its user.")
    config = configparser.ConfigParser(interpolation=None, strict=False)
    with open(path) as file:
        config.read_file(file)
    if name == "wf-shell.ini":
        battery = any("battery" in config.get(section, option, fallback="").split()
                      for section in config.sections()
                      if section == "panel" or section.startswith("panel:")
                      for option in ("widgets_left", "widgets_center", "widgets_right"))
        if battery and (not os.access("/usr/libexec/upowerd", os.X_OK)
                        or not os.path.isfile("/usr/share/dbus-1/system-services/org.freedesktop.UPower.service")):
            sys.exit("Panel battery widget requires UPower. Install upower or remove the battery widget.")
    if name == "wayfire.ini" and os.path.exists("/usr/local/sbin/void-installer-chezmoi-gui"):
        if ("autostart" not in config.get("core", "plugins", fallback="").split()
                or config.get("autostart", "void_installer_chezmoi", fallback="")
                != "/usr/local/sbin/void-installer-chezmoi-gui"):
            sys.exit("Wayfire's graphical first-login setup hook is missing or invalid.")
if os.path.exists("/usr/local/sbin/void-installer-chezmoi-gui"):
    for path in ("/usr/local/sbin/void-installer-chezmoi", "/usr/local/sbin/void-installer-chezmoi-gui"):
        if os.path.islink(path) or not os.access(path, os.X_OK) or os.stat(path).st_uid != 0:
            sys.exit("First-login setup helper is missing or not owned by root.")
    with open("/etc/void-installer/chezmoi.conf") as file:
        setup = dict(line.rstrip("\n").split("=", 1) for line in file)
    if setup.get("USERNAME") != user or not setup.get("REPOSITORY"):
        sys.exit("First-login setup configuration does not match the desktop user.")
DESKTOP_CHECK_EOF
}

configure_chezmoi_first_login() {
  local target=${1:-/mnt}
  local config=$target/etc/void-installer/chezmoi.conf
  local helper=$target/usr/local/sbin/void-installer-chezmoi
  local gui=$target/usr/local/sbin/void-installer-chezmoi-gui path
  local profile=$target/home/$USERNAME/.bash_profile
  if [[ -z $CHEZMOI_REPO || $CHEZMOI_MODE != first-login ]]; then
    return 0
  fi
  for path in "$config" "$helper" "$gui" "$profile"; do
    if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
      echo "Unsafe first-login setup destination: $path" >&2
      return 1
    fi
  done
  mkdir -p "$target/etc/void-installer" "$target/usr/local/sbin"
  printf 'USERNAME=%s\nREPOSITORY=%s\n' "$USERNAME" "$CHEZMOI_REPO" > "$config"
  chmod 0644 "$config"
  cat > "$helper" <<'CHEZMOI_EOF'
#!/bin/bash
set -Eeuo pipefail
umask 077

config=/etc/void-installer/chezmoi.conf
expected_user=
repository=
while IFS='=' read -r key value; do
  case $key in
    USERNAME) expected_user=$value ;;
    REPOSITORY) repository=$value ;;
  esac
done < "$config"
if [[ -z $expected_user || -z $repository || $(id -un) != "$expected_user" || $EUID -eq 0 ]]; then
  echo "This setup command is only available to the configured non-root user." >&2
  exit 1
fi
if [[ ! -t 0 || ! -t 1 ]]; then
  echo "Run this command from an interactive terminal." >&2
  exit 1
fi
if (( $# > 1 )) || { (( $# == 1 )) && [[ $1 != --retry ]]; }; then
  echo "Usage: void-installer-chezmoi [--retry]" >&2
  exit 2
fi

state_dir="$HOME/.local/state/void-installer"
mkdir -p "$state_dir"
chmod 0700 "$state_dir"
status_file="$state_dir/chezmoi.status"
write_status() {
  local tmp="$status_file.tmp.$$"
  printf '%s\n' "$1" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$status_file"
}
exec 9>"$state_dir/chezmoi.lock"
if ! flock -n 9; then
  echo "chezmoi setup is already running in another session." >&2
  exit 1
fi
status=
if [[ -r $status_file ]]; then IFS= read -r status < "$status_file" || true; fi
if [[ $status == complete ]]; then
  exit 0
fi
if [[ ($status == failed || $status == running) && ${1:-} != --retry ]]; then
  echo "chezmoi setup previously failed or was interrupted. Retry with: void-installer-chezmoi --retry" >&2
  exit 1
fi
write_status running
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    write_status failed || true
    echo "chezmoi setup failed or was interrupted. Retry in a terminal with: void-installer-chezmoi --retry" >&2
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if ! command -v chezmoi >/dev/null 2>&1; then
  echo "chezmoi is not installed. Install it, then run void-installer-chezmoi --retry." >&2
  exit 1
fi
if [[ -d $HOME/.local/share/chezmoi ]]; then
  chezmoi apply
else
  chezmoi init --apply "$repository"
fi
write_status complete
trap - EXIT
echo "chezmoi setup completed."
CHEZMOI_EOF
  chmod 0755 "$helper"
  cat > "$gui" <<'CHEZMOI_GUI_EOF'
#!/bin/bash
set -Eeuo pipefail
umask 077

config=/etc/void-installer/chezmoi.conf
expected_user=
repository=
while IFS='=' read -r key value; do
  case $key in
    USERNAME) expected_user=$value ;;
    REPOSITORY) repository=$value ;;
  esac
done < "$config"
if [[ -z $expected_user || -z $repository || $(id -un) != "$expected_user" || $EUID -eq 0 || -z ${WAYLAND_DISPLAY:-} ]]; then
  exit 0
fi
state_dir="$HOME/.local/state/void-installer"
mkdir -p "$state_dir"
chmod 0700 "$state_dir"
# Keep one setup terminal open at a time, including while kitty holds output.
exec 8>"$state_dir/chezmoi-gui.lock"
flock -n 8 || exit 0
# Check the console helper's lock before opening a terminal. The helper takes
# it again inside kitty; it remains the authority if a tty login races us.
exec 9>"$state_dir/chezmoi.lock"
flock -n 9 || exit 0
status=
if [[ -r $state_dir/chezmoi.status ]]; then IFS= read -r status < "$state_dir/chezmoi.status" || true; fi
case $status in complete|failed|running) exit 0 ;; esac
flock -u 9
exec 9>&-
kitty --hold --title "Void dotfiles setup" /usr/local/sbin/void-installer-chezmoi
CHEZMOI_GUI_EOF
  chmod 0755 "$gui"
  if [[ ! -e $profile ]]; then
    : > "$profile"
  fi
  if ! grep -Fq '# void-installer chezmoi first-login hook' "$profile"; then
    cat >> "$profile" <<'PROFILE_EOF'

# void-installer chezmoi first-login hook
if [[ $- == *i* && -t 0 && -t 1 ]]; then
  /usr/local/sbin/void-installer-chezmoi || true
fi
PROFILE_EOF
  fi
  chroot "$target" chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"
  chroot "$target" python3 - "$USERNAME" <<'CHEZMOI_AUTOSTART_EOF'
import configparser
import os
import pathlib
import re
import sys
import tempfile

path = pathlib.Path(f"/home/{sys.argv[1]}/.config/wayfire.ini")
if path.parent.is_symlink() or path.is_symlink() or not path.is_file():
    raise SystemExit("Safe Wayfire configuration is required for first-login setup.")
original = path.read_text()
config = configparser.ConfigParser(interpolation=None, strict=False)
config.read_string(original)
if "autostart" not in config.get("core", "plugins", fallback="").split():
    raise SystemExit("Wayfire's autostart plugin is required for first-login setup.")
key = "void_installer_chezmoi"
command = "/usr/local/sbin/void-installer-chezmoi-gui"
current = config.get("autostart", key, fallback=None)
if current is not None:
    if current != command:
        raise SystemExit("Existing Wayfire first-login entry differs; refusing to overwrite it.")
    raise SystemExit(0)
lines = original.splitlines(keepends=True)
for index, line in enumerate(lines):
    if re.match(r"^\s*\[autostart\]\s*(?:#.*)?$", line):
        if not line.endswith("\n"):
            lines[index] += "\n"
        lines.insert(index + 1, f"{key} = {command}\n")
        break
else:
    lines.append(f"\n[autostart]\n{key} = {command}\n")
info = path.stat()
fd, name = tempfile.mkstemp(prefix=".wayfire.", dir=path.parent)
try:
    with os.fdopen(fd, "w") as file:
        file.write("".join(lines))
        os.fchown(file.fileno(), info.st_uid, info.st_gid)
        os.fchmod(file.fileno(), info.st_mode & 0o777)
    os.replace(name, path)
finally:
    if os.path.exists(name):
        os.unlink(name)
CHEZMOI_AUTOSTART_EOF
  echo "Configured first-login chezmoi in kitty and on the recovery console."
}

# --------------------------------------------------------------------------
# chezmoi dotfiles (spec section 13)
# --------------------------------------------------------------------------

apply_chezmoi() {
  if [[ -z $CHEZMOI_REPO || $CHEZMOI_MODE != install ]]; then
    return 0
  fi
  if [[ -e /mnt/etc/sudoers.d/99-installer ]]; then
    echo "Refusing to overwrite existing /etc/sudoers.d/99-installer." >&2
    return 1
  fi
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" > /mnt/etc/sudoers.d/99-installer
  INSTALLER_SUDOERS_CREATED=1
  chmod 0440 /mnt/etc/sudoers.d/99-installer
  if ! chroot /mnt su - "$USERNAME" -c "chezmoi init --apply --force '$CHEZMOI_REPO'" </dev/null; then
    CHEZMOI_FAILED=1
  fi
  rm -f /mnt/etc/sudoers.d/99-installer
  INSTALLER_SUDOERS_CREATED=0
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
  if ! chroot /mnt snapper --no-dbus -c root list | grep -Fq "Initial installation"; then
    chroot /mnt snapper --no-dbus -c root create -c number -d "Initial installation"
  fi
  chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
}

# --------------------------------------------------------------------------
# Finalize, error handling (spec sections 10.14, 10)
# --------------------------------------------------------------------------

finalize() {
  if (( INSTALLER_SUDOERS_CREATED == 1 )); then
    rm -f /mnt/etc/sudoers.d/99-installer   # temporary NOPASSWD rule (section 13)
    INSTALLER_SUDOERS_CREATED=0
  fi
  rm -f /mnt/etc/resolv.conf                # NetworkManager manages it at boot
  if [[ -n $INSTALL_STATE ]]; then
    INSTALL_STATE_STEP=$INSTALLER_TOTAL_STEPS
    INSTALL_STATE_CHECKPOINT="complete"
    INSTALL_STATUS="complete"
    write_install_state
  fi
  preserve_install_log
  unmount_owned
  if (( ${#INSTALL_MOUNTS[@]} > 0 )); then
    echo "Some installer-owned mounts remain; see the log before rebooting." >&2
    return 1
  fi
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
  preserve_install_log || true
  cleanup_probe_cache || true
  if (( INSTALLER_SUDOERS_CREATED == 1 )) && [[ -d /mnt/etc/sudoers.d ]]; then
    rm -f /mnt/etc/sudoers.d/99-installer 2>/dev/null || true
  fi
  unmount_owned || true
}

on_error() {
  echo "Installation failed at step $CURRENT_STEP_N ($CURRENT_STEP_NAME), line $1." >&2
  exit 1
}

# --------------------------------------------------------------------------
# Step orchestration (spec section 10)
# --------------------------------------------------------------------------

run_step() {  # $1 = N, $2 = name, $3 = checkpoint, rest = function
  CURRENT_STEP_N=$1
  CURRENT_STEP_NAME=$2
  printf '==> [%s/%s] %s\n' "$1" "$INSTALLER_TOTAL_STEPS" "$2" | tee -a "$INSTALLER_LOG"
  local checkpoint=$3
  shift 3
  case $CURRENT_STEP_N in
    5|8|20) "$@" ;;  # keep dialogs and arbitrary dotfile output outside the log
    *) "$@" > >(tee -a "$INSTALLER_LOG") 2> >(tee -a "$INSTALLER_LOG" >&2) ;;
  esac
  if [[ -n $INSTALL_STATE && -f $INSTALL_STATE && $INSTALL_STATE_STEP -lt $CURRENT_STEP_N ]]; then
    INSTALL_STATE_STEP=$CURRENT_STEP_N
    INSTALL_STATE_CHECKPOINT=$checkpoint
    INSTALL_STATUS=active
    write_install_state
  fi
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
  initialize_install_state
}

step_repair_partial_packages() {
  local rc=0
  chroot /mnt xbps-pkgdb -a || rc=$?
  if (( rc != 0 )); then
    echo "Target package database needs repair; reconfiguring installed packages before retry." >&2
    chroot /mnt xbps-reconfigure -a || true
    chroot /mnt xbps-pkgdb -a || {
      echo "Package database audit still fails. Use --repair ROOT_PARTITION --action chroot and inspect with xbps-pkgdb -a before resuming." >&2
      return 1
    }
  fi
}

resume_secrets() {
  local status
  if (( INSTALL_STATE_STEP < 13 )) && [[ -n $WIFI_SSID && $WIFI_SECURITY == wpa-psk && ! -v WIFI_PASSWORD ]]; then
    prompt_wifi_password
  fi
  if (( INSTALL_STATE_STEP < 17 )); then
    status=$(LC_ALL=C chroot /mnt passwd -S "$USERNAME" 2>/dev/null || true)
    if [[ ${status#* } != P* ]] && [[ ! -v USER_PASSWORD && ! -v USER_PASSWORD_HASH ]]; then
      prompt_password
    fi
    status=$(LC_ALL=C chroot /mnt passwd -S root 2>/dev/null || true)
    if [[ ${status#* } != P* ]] && [[ ! -v ROOT_PASSWORD && ! -v ROOT_PASSWORD_HASH ]]; then
      prompt_root_password
    fi
  fi
}

load_resume_state() {
  local actual_root actual_esp actual_disk
  identify_existing_devices
  if findmnt -rn -o TARGET | awk '$0 == "/mnt" || index($0, "/mnt/") == 1 { found=1 } END { exit !found }' \
      || [[ -n $(find /mnt -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
    echo "The /mnt tree must be empty and unmounted before resume." >&2; return 1
  fi
  actual_root=$ROOT_UUID; actual_esp=$ESP_UUID; actual_disk=$TARGET_DISK
  mount_owned /mnt -o "$BTRFS_OPTS,subvol=@" "$ROOT_PARTITION" /mnt
  INSTALL_STATE=/mnt/var/lib/void-installer/state
  read_install_state "$INSTALL_STATE"
  if [[ $ROOT_UUID != "$actual_root" || $ESP_UUID != "$actual_esp" || $TARGET_DISK != "$actual_disk" ]]; then
    echo "Installer state device identities do not match the selected root partition." >&2
    return 1
  fi
  apply_defaults
  unset USER_PASSWORD USER_PASSWORD_HASH ROOT_PASSWORD ROOT_PASSWORD_HASH WIFI_PASSWORD
  [[ $CHEZMOI_MODE != install || $INSTALL_STATE_STEP != 19 ]] || {
    echo "Install-time chezmoi was interrupted after checkpoint 19; it can run arbitrary dotfile scripts. Resume is stopped. Use --repair ROOT_PARTITION --action chroot, then inspect and repair manually." >&2
    return 1
  }
  local key
  for key in HOSTNAME USERNAME USER_SHELL TIMEZONE LOCALE KEYMAP MIRROR SWAP CHEZMOI_MODE WIFI_SECURITY WIFI_HIDDEN CHEZMOI_REPO EXTRA_PACKAGES HW_CHASSIS HW_TOUCH HW_FINGERPRINT HW_BLUETOOTH; do
    if ! validate_one "$key" "${!key-}"; then
      echo "Saved installer state has invalid $key: $VALIDATE_REASON" >&2
      return 1
    fi
  done
  if [[ -n $WIFI_SSID ]] && ! validate_one WIFI_SSID "$WIFI_SSID"; then
    echo "Saved installer state has invalid WIFI_SSID: $VALIDATE_REASON" >&2
    return 1
  fi
  mount_existing_layout
  mount_target_bindings
  cp /etc/resolv.conf /mnt/etc/resolv.conf
  resume_secrets
}

repair_menu() {
  local choice
  if [[ -n $REPAIR_ACTION ]]; then return 0; fi
  if command -v dialog >/dev/null 2>&1; then
    REPAIR_ACTION=$(dialog --clear --title "Void installer repair" --menu "Choose an action" 15 72 6 \
      check "Check installation" chroot "Open target shell" password "Set account password" \
      grub "Reinstall GRUB" initramfs "Regenerate initramfs" 3>&1 1>&2 2>&3) || return 4
  else
    printf 'Repair action: 1 check, 2 chroot, 3 password, 4 grub, 5 initramfs: '
    read -r choice
    case $choice in 1) REPAIR_ACTION=check ;; 2) REPAIR_ACTION=chroot ;; 3) REPAIR_ACTION=password ;; 4) REPAIR_ACTION=grub ;; 5) REPAIR_ACTION=initramfs ;; *) return 4 ;; esac
  fi
}

repair_password() {
  local username=$REPAIR_USER
  if [[ -z $username ]]; then
    if command -v dialog >/dev/null 2>&1; then
      username=$(dialog --clear --title "Account password" --inputbox "Account name (root is allowed)" 10 70 3>&1 1>&2 2>&3) || return 4
    else
      read -r -p "Account name (root is allowed): " username
    fi
  fi
  [[ $username == root || $username =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid account name." >&2; return 2; }
  chroot /mnt id -u "$username" >/dev/null || { echo "Account does not exist: $username" >&2; return 1; }
  chroot /mnt passwd "$username"
}

run_repair_action() {
  local kernel version
  repair_menu
  case $REPAIR_ACTION in
    check) validate_target_installation ;;
    chroot) chroot /mnt /bin/bash -l ;;
    password) repair_password ;;
    grub) setup_grub; validate_target_installation ;;
    initramfs)
      compgen -G '/mnt/usr/lib/modules/*' >/dev/null || { echo "No installed kernel modules found." >&2; return 1; }
      for kernel in /mnt/usr/lib/modules/*; do
        [[ -d $kernel ]] || continue
        version=${kernel##*/}
        chroot /mnt dracut --force "/boot/initramfs-$version.img" "$version"
      done
      validate_target_installation
      ;;
  esac
}

run_resume() {
  apply_defaults
  preflight
  load_resume_state
  detect_hardware
  build_package_lists
  probe_packages
  if (( INSTALL_STATE_STEP == 11 )); then step_repair_partial_packages; fi
  if (( INSTALL_STATE_STEP < 11 )); then run_step 11 "Prepare target for bootstrap" bootstrap-prepared bootstrap_prepare; fi
  if (( INSTALL_STATE_STEP < 12 )); then run_step 12 "Install packages" packages-installed bootstrap_install; fi
  if (( INSTALL_STATE_STEP < 13 )); then run_step 13 "Configure base system" system-configured configure_system; fi
  if (( INSTALL_STATE_STEP < 14 )); then run_step 14 "Configure Snapper" snapper-configured setup_snapper; fi
  if (( INSTALL_STATE_STEP < 15 )); then run_step 15 "Install GRUB" bootloader-configured setup_grub; fi
  if (( INSTALL_STATE_STEP < 16 )); then run_step 16 "Enable services" services-enabled enable_services; fi
  if (( INSTALL_STATE_STEP < 17 )); then run_step 17 "Configure accounts" accounts-configured create_user; fi
  if (( INSTALL_STATE_STEP < 18 )); then run_step 18 "Configure desktop" desktop-configured configure_desktop; fi
  if (( INSTALL_STATE_STEP < 19 )); then run_step 19 "Configure first-login dotfiles" chezmoi-hook-configured configure_chezmoi_first_login; fi
  if (( INSTALL_STATE_STEP < 20 )); then run_step 20 "Apply chezmoi dotfiles" chezmoi-applied apply_chezmoi; fi
  if (( INSTALL_STATE_STEP < 21 )); then run_step 21 "Install xbps wrappers" wrappers-installed install_wrappers; fi
  if (( INSTALL_STATE_STEP < 22 )); then run_step 22 "Create initial snapshot" initial-snapshot initial_snapshot; fi
  if (( INSTALL_STATE_STEP < 23 )); then run_step 23 "Validate installed system" validated validate_target_installation; fi
  run_step 24 "Finalize" complete finalize
}

run_repair() {
  [[ $EUID -eq 0 ]] || { echo "Repair mode must be run as root." >&2; return 1; }
  [[ -d /sys/firmware/efi ]] || { echo "Repair mode requires UEFI boot." >&2; return 1; }
  identify_existing_devices
  mount_existing_layout
  mount_target_bindings
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
  SV_FATAL=(dbus polkitd NetworkManager chronyd acpid grub-btrfs)
  run_repair_action
}

validate_target_installation() {
  local mountpoint expected_uuid kernel kernel_version found_kernel=0 found_efi=0
  for mountpoint in / /home /.snapshots /var/log /var/cache/xbps /var/tmp; do
    expected_uuid=$ROOT_UUID
    if ! awk -v uuid="UUID=$expected_uuid" -v mountpoint="$mountpoint" '$1 == uuid && $2 == mountpoint { found=1 } END { exit !found }' /mnt/etc/fstab; then
      echo "Installed fstab is missing the expected Btrfs mount for $mountpoint." >&2
      return 1
    fi
  done
  if ! awk -v uuid="UUID=$ESP_UUID" '$1 == uuid && $2 == "/boot/efi" { found=1 } END { exit !found }' /mnt/etc/fstab; then
    echo "Installed fstab is missing the EFI partition entry." >&2
    return 1
  fi
  for kernel in /mnt/boot/vmlinuz-*; do
    [[ -s $kernel ]] || continue
    kernel_version=${kernel##*/vmlinuz-}
    if [[ -s /mnt/boot/initramfs-$kernel_version.img ]]; then
      found_kernel=1
      break
    fi
  done
  if (( found_kernel == 0 )); then
    echo "No installed kernel has a matching initramfs in /boot." >&2
    return 1
  fi
  if [[ ! -s /mnt/boot/grub/grub.cfg ]]; then
    echo "GRUB configuration is missing or empty." >&2
    return 1
  fi
  if [[ -d /mnt/boot/efi/EFI ]]; then
    while IFS= read -r -d '' _; do found_efi=1; break; done < <(find /mnt/boot/efi/EFI -mindepth 2 -maxdepth 2 -type f -iname grubx64.efi -print0)
  fi
  if (( found_efi == 0 )); then
    echo "GRUB EFI executable is missing from the EFI partition." >&2
    return 1
  fi
  validate_elogind_activation /mnt
  if [[ -f /mnt/etc/NetworkManager/system-connections/installer-wifi.nmconnection ]]; then
    if ! chroot /mnt nmcli --offline connection modify type wifi \
        < /mnt/etc/NetworkManager/system-connections/installer-wifi.nmconnection >/dev/null 2>&1; then
      echo "The installed NetworkManager could not parse its Wi-Fi profile." >&2
      return 1
    fi
  fi
  if [[ ! -s /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
    echo "EFI removable-media fallback executable is missing." >&2
    return 1
  fi
  validate_enabled_services /mnt
  if ! chroot /mnt visudo -c; then
    echo "Installed sudo configuration failed validation." >&2
    return 1
  fi
  validate_desktop_installation /mnt
  validate_greetd_installation /mnt
  echo "Installed boot files, services, sudo, and desktop configuration validated."
}

bootstrap_prepare() { bootstrap_system prepare; }
bootstrap_install()  { bootstrap_system install; }

main() {
  trap cleanup EXIT
  trap 'on_error $LINENO' ERR

  echo "void-installer $INSTALLER_VERSION"
  parse_args "$@"
  INSTALLER_LOG=$(mktemp /tmp/void-installer.XXXXXX)
  chmod 0600 "$INSTALLER_LOG"
  printf 'void-installer %s\n' "$INSTALLER_VERSION" > "$INSTALLER_LOG"
  printf 'Installer output log: %s\n' "$INSTALLER_LOG" | tee -a "$INSTALLER_LOG"

  if (( RESUME_MODE == 1 )); then
    run_resume
    return
  elif (( REPAIR_MODE == 1 )); then
    run_repair
    echo "Repair action '$REPAIR_ACTION' finished."
    return
  fi

  run_step  1 "Parse arguments and load configuration" settings-loaded load_settings
  run_step  2 "Preflight checks" preflight-passed preflight
  run_step  3 "Detect hardware" hardware-detected detect_hardware
  run_step  4 "Build package lists" packages-planned build_package_lists
  run_step  5 "Select disk and prompt for missing values" values-selected step_interactive
  run_step  6 "Validate configuration" configuration-validated validate_all
  run_step  7 "Probe packages and services" packages-probed probe_packages
  run_step  8 "Confirm installation" installation-confirmed confirm
  run_step  9 "Partition disk" disk-partitioned partition_disk
  run_step 10 "Create filesystems and mount" filesystems-mounted step_filesystems
  run_step 11 "Prepare target for bootstrap" bootstrap-prepared bootstrap_prepare
  run_step 12 "Install packages" packages-installed bootstrap_install
  run_step 13 "Configure base system" system-configured configure_system
  run_step 14 "Configure Snapper" snapper-configured setup_snapper
  run_step 15 "Install GRUB" bootloader-configured setup_grub
  run_step 16 "Enable services" services-enabled enable_services
  run_step 17 "Configure accounts" accounts-configured create_user
  run_step 18 "Configure desktop" desktop-configured configure_desktop
  run_step 19 "Configure first-login dotfiles" chezmoi-hook-configured configure_chezmoi_first_login
  run_step 20 "Apply chezmoi dotfiles" chezmoi-applied apply_chezmoi
  run_step 21 "Install xbps wrappers" wrappers-installed install_wrappers
  run_step 22 "Create initial snapshot" initial-snapshot initial_snapshot
  run_step 23 "Validate installed system" validated validate_target_installation
  run_step 24 "Finalize" complete finalize
}

main "$@"

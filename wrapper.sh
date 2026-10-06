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

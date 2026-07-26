#!/bin/sh
# Copia exacta UnlockCD remote_mount_dynamic.sh
set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/System/Library/Filesystems/apfs.fs
APFS_UTIL=/System/Library/Filesystems/apfs.fs/apfs.util
MOUNT_APFS=/System/Library/Filesystems/apfs.fs/mount_apfs
[ -x "$MOUNT_APFS" ] || MOUNT_APFS=/sbin/mount_apfs
USE_OBLIT="${HFZ_SAFE_OBLIT:-0}"
log(){ echo "[remote-mount] $*"; }
ready_data(){ [ -d /mnt2/mobile ] && [ -d /mnt2/root ] && [ -d /mnt2/containers ]; }
ready_user(){ [ -d /mnt8/Library/Preferences ] || [ -d /mnt8/Library ]; }
label_of(){ "$APFS_UTIL" -p "$1" 2>/dev/null | sed -n '1p'; }
mounted_on(){ mp="$1"; (/sbin/mount 2>/dev/null || /bin/mount 2>/dev/null) | awk -v m="$mp" '$3==m{print $1; exit}'; }
cleanup_oblit(){
  /usr/sbin/nvram -d oblit-inprogress >/dev/null 2>&1 || true
  /usr/sbin/nvram auto-boot=true >/dev/null 2>&1 || true
}
mount_once(){
  dev="$1"; mp="$2"
  [ -n "$dev" ] || return 1
  /bin/mkdir -p "$mp" 2>/dev/null
  cur=$(mounted_on "$mp")
  if [ -n "$cur" ]; then
    [ "$cur" = "$dev" ] && { log "skip $mp: already mounted as $cur"; return 0; }
    /sbin/umount "$mp" 2>/dev/null || true
  fi
  log "mount $dev -> $mp"
  "$MOUNT_APFS" "$dev" "$mp"
  return $?
}

cleanup_oblit
for d in /mnt1 /mnt2 /mnt3 /mnt4 /mnt5 /mnt6 /mnt7 /mnt8; do /bin/mkdir -p "$d" 2>/dev/null; done
if ready_data; then log "/mnt2 already ready"; exit 0; fi

SYS=""; DATA=""; PREBOOT=""; XART=""; USER=""
for prefix in /dev/disk1s /dev/disk0s1s; do
  for i in 1 2 3 4 5 6 7 8 9; do
    dev="${prefix}${i}"; [ -e "$dev" ] || continue
    lab=$(label_of "$dev")
    case "$lab" in
      System) [ -z "$SYS" ] && SYS="$dev";;
      Data) [ -z "$DATA" ] && DATA="$dev";;
      Preboot) [ -z "$PREBOOT" ] && PREBOOT="$dev";;
      xART) [ -z "$XART" ] && XART="$dev";;
      User) [ -z "$USER" ] && USER="$dev";;
    esac
  done
done
[ -n "$SYS" ] && mount_once "$SYS" /mnt1
[ -n "$PREBOOT" ] && mount_once "$PREBOOT" /mnt6
[ -n "$XART" ] && mount_once "$XART" /mnt7

SEP=""
if [ -f /mnt6/active ]; then
  active=$(/bin/cat /mnt6/active 2>/dev/null)
  [ -n "$active" ] && SEP="/mnt6/$active/usr/standalone/firmware/sep-firmware.img4"
fi
[ -f "$SEP" ] || SEP=$(find /mnt6 -iname sep-firmware.img4 2>/dev/null | head -1)
[ -f "$SEP" ] || SEP=/mnt1/usr/standalone/firmware/sep-firmware.img4

if [ -f "$SEP" ]; then
  /usr/libexec/seputil --gigalocker-init
  /usr/libexec/seputil --load "$SEP"
fi

mount_once "$DATA" /mnt2
cleanup_oblit
if ! ready_data; then log "mnt2 not ready"; exit 75; fi
log "mnt2 ready"
if [ "${HFZ_MOUNT_USER:-0}" = "1" ]; then
  [ -n "$USER" ] && mount_once "$USER" /mnt8
fi
cleanup_oblit
exit 0

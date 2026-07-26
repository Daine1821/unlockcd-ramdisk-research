#!/bin/sh
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
    log "$mp mounted as $cur, remount $dev"
    /sbin/umount "$mp" 2>/dev/null || /sbin/umount -f "$mp" 2>/dev/null || true
  fi
  log "mount $dev -> $mp"
  "$MOUNT_APFS" "$dev" "$mp"
  rc=$?
  [ $rc -eq 0 ] || log "mount failed rc=$rc: $dev -> $mp"
  return $rc
}

cleanup_oblit
for d in /mnt1 /mnt2 /mnt3 /mnt4 /mnt5 /mnt6 /mnt7 /mnt8; do /bin/mkdir -p "$d" 2>/dev/null; done
if ready_data; then
  log "/mnt2 already ready"
  exit 0
fi

SYS=""; DATA=""; PREBOOT=""; XART=""; USER=""
for prefix in /dev/disk1s /dev/disk0s1s; do
  for i in 1 2 3 4 5 6 7 8 9; do
    dev="${prefix}${i}"; [ -e "$dev" ] || continue
    lab=$(label_of "$dev")
    [ -n "$lab" ] && log "$dev label=$lab"
    case "$lab" in
      System) [ -z "$SYS" ] && SYS="$dev";;
      Data) [ -z "$DATA" ] && DATA="$dev";;
      Preboot) [ -z "$PREBOOT" ] && PREBOOT="$dev";;
      xART) [ -z "$XART" ] && XART="$dev";;
      User) [ -z "$USER" ] && USER="$dev";;
    esac
  done
done
[ -z "$SYS" ] && [ -e /dev/disk1s1 ] && SYS=/dev/disk1s1
[ -z "$DATA" ] && [ -e /dev/disk1s2 ] && DATA=/dev/disk1s2
log "resolved sys=${SYS:-N/A} data=${DATA:-N/A} preboot=${PREBOOT:-N/A} xart=${XART:-N/A} user=${USER:-N/A} safe_oblit=$USE_OBLIT"

[ -n "$SYS" ] && mount_once "$SYS" /mnt1 || true
[ -n "$PREBOOT" ] && mount_once "$PREBOOT" /mnt6 || true
[ -n "$XART" ] && mount_once "$XART" /mnt7 || true

SEP=""
if [ -f /mnt6/active ]; then
  active=$(/bin/cat /mnt6/active 2>/dev/null)
  [ -n "$active" ] && SEP="/mnt6/$active/usr/standalone/firmware/sep-firmware.img4"
fi
if [ -z "$SEP" ] || [ ! -f "$SEP" ]; then
  first=$(/bin/ls /mnt6 2>/dev/null | /usr/bin/grep -E '^[0-9A-Fa-f]{40,}$' | /usr/bin/head -n1)
  [ -n "$first" ] && SEP="/mnt6/$first/usr/standalone/firmware/sep-firmware.img4"
fi
[ -f "$SEP" ] || SEP=/mnt1/usr/standalone/firmware/sep-firmware.img4

if [ -f "$SEP" ]; then
  log "gigalocker-init"
  /usr/libexec/seputil --gigalocker-init 2>&1 | sed 's/^/[remote-mount] /'
  log "seputil --load $SEP"
  /usr/libexec/seputil --load "$SEP" 2>&1 | sed 's/^/[remote-mount] /'
  log "seputil load rc=$?"
else
  log "SEP not found"
fi

DATA2=""; USER2=""
for prefix in /dev/disk1s /dev/disk0s1s; do
  for i in 1 2 3 4 5 6 7 8 9; do
    dev="${prefix}${i}"; [ -e "$dev" ] || continue
    lab=$(label_of "$dev")
    [ -n "$lab" ] && log "post-sep $dev label=$lab"
    case "$lab" in
      Data) [ -z "$DATA2" ] && DATA2="$dev";;
      User) [ -z "$USER2" ] && USER2="$dev";;
    esac
  done
done
[ -n "$DATA2" ] && DATA="$DATA2"
[ -n "$USER2" ] && USER="$USER2"
log "post-sep resolved data=${DATA:-N/A} user=${USER:-N/A}"

ba=$(/usr/sbin/nvram -p 2>/dev/null | /usr/bin/grep '^boot-args' 2>/dev/null || true)
case "$ba" in
  *nand-enable-reformat=1*)
    log "refuse Data mount: current boot-args contain nand-enable-reformat=1: $ba"
    cleanup_oblit
    exit 76
    ;;
esac

if [ "$USE_OBLIT" = "1" ] || [ "$USE_OBLIT" = "auto" ]; then
  log "set temporary nvram guard: auto-boot=false + oblit-inprogress=1 rev=2"
  /usr/sbin/nvram auto-boot=false >/dev/null 2>&1 || true
  /usr/sbin/nvram oblit-inprogress=1 rev=2 >/dev/null 2>&1 || true
fi

mount_once "$DATA" /mnt2
mrc=$?
sleep 1
cleanup_oblit

if ! ready_data; then
  log "mnt2 not ready after data mount rc=$mrc"
  exit 75
fi
log "mnt2 ready"

if [ "${HFZ_MOUNT_USER:-0}" = "1" ]; then
  [ -n "$USER" ] && mount_once "$USER" /mnt8 || true
  ready_user && log "mnt8 ready"
else
  log "skip User mount; set HFZ_MOUNT_USER=1 to enable"
fi
cleanup_oblit
exit 0

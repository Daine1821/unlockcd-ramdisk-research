#!/bin/sh
set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/System/Library/Filesystems/apfs.fs
APFS_UTIL=/System/Library/Filesystems/apfs.fs/apfs.util
MOUNT_APFS=/System/Library/Filesystems/apfs.fs/mount_apfs
[ -x "$MOUNT_APFS" ] || MOUNT_APFS=/sbin/mount_apfs
log(){ echo "[remote-old] $*"; }
run_bg_timeout(){
  _sec="$1"; shift
  "$@" &
  _pid=$!
  _i=0
  while kill -0 "$_pid" 2>/dev/null; do
    if [ "$_i" -ge "$_sec" ]; then
      log "timeout ${_sec}s: $*"
      kill -9 "$_pid" 2>/dev/null || true
      wait "$_pid" 2>/dev/null
      return 124
    fi
    sleep 1
    _i=$((_i+1))
  done
  wait "$_pid"
  return $?
}
label_of(){ "$APFS_UTIL" -p "$1" 2>/dev/null | sed -n '1p'; }
cleanup_oblit(){
  /usr/sbin/nvram -d oblit-inprogress >/dev/null 2>&1 || true
  /usr/sbin/nvram -d obliteration >/dev/null 2>&1 || true
  /usr/sbin/nvram -d rev >/dev/null 2>&1 || true
  /usr/sbin/nvram auto-boot=true >/dev/null 2>&1 || true
}
ready_data(){ [ -d /mnt2/mobile ] && [ -d /mnt2/root ] && [ -d /mnt2/containers ]; }

cleanup_oblit
if ready_data; then
  log "/mnt2 already ready"
  exit 0
fi

PREBOOT=""; XART=""; DATA=""; SYSTEM=""
for prefix in /dev/disk1s /dev/disk0s1s; do
  for i in 1 2 3 4 5 6 7 8 9; do
    dev="${prefix}${i}"
    [ -e "$dev" ] || continue
    lab=$(label_of "$dev")
    [ -n "$lab" ] && log "$dev label=$lab"
    case "$lab" in
      System)  [ -z "$SYSTEM" ] && SYSTEM="$dev" ;;
      Preboot) [ -z "$PREBOOT" ] && PREBOOT="$dev" ;;
      xART)    [ -z "$XART" ] && XART="$dev" ;;
      Data)    [ -z "$DATA" ] && DATA="$dev" ;;
    esac
  done
done
[ -z "$SYSTEM" ] && [ -e /dev/disk1s1 ] && SYSTEM=/dev/disk1s1
[ -z "$PREBOOT" ] && [ -e /dev/disk1s6 ] && PREBOOT=/dev/disk1s6
[ -z "$XART" ] && [ -e /dev/disk1s3 ] && XART=/dev/disk1s3
[ -z "$DATA" ] && [ -e /dev/disk1s2 ] && DATA=/dev/disk1s2
log "resolved system=${SYSTEM:-N/A} preboot=${PREBOOT:-N/A} xart=${XART:-N/A} data=${DATA:-N/A}"
[ -n "$XART" ] || { log "missing xART"; exit 72; }
[ -n "$DATA" ] || { log "missing Data"; exit 73; }

/bin/mkdir -p /mnt1 /mnt2 /mnt6 /mnt7 2>/dev/null

if [ -n "$SYSTEM" ]; then
  log "mount System $SYSTEM -> /mnt1"
  "$MOUNT_APFS" "$SYSTEM" /mnt1 2>&1 || true
fi
if [ -n "$PREBOOT" ]; then
  log "mount Preboot $PREBOOT -> /mnt6"
  "$MOUNT_APFS" "$PREBOOT" /mnt6 2>&1 || true
else
  log "no Preboot volume; will load SEP from /mnt1 fallback"
fi
log "mount xART $XART -> /mnt7"
"$MOUNT_APFS" "$XART" /mnt7 2>&1 || true
/bin/ls -l /mnt7 2>&1 | head -20 || true

if [ -z "$PREBOOT" ]; then
  log "no Preboot detected; try direct Data mount before seputil"
  run_bg_timeout 12 "$MOUNT_APFS" "$DATA" /mnt2
  mrc=$?
  log "direct Data mount rc=$mrc"
  if ready_data; then
    log "/mnt2 ready by direct old-layout mount"
    cleanup_oblit
    /bin/sync
    exit 0
  fi
  log "direct Data not ready; continue old seputil path"
fi

log "set old nvram guard: auto-boot=false + oblit-inprogress=1 rev=2"
/usr/sbin/nvram auto-boot=false 2>/dev/null || true
/usr/sbin/nvram oblit-inprogress=1 rev=2 2>/dev/null || true

log "gigalocker-init"
run_bg_timeout 20 /usr/libexec/seputil --gigalocker-init

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
log "seputil --load $SEP"
run_bg_timeout 20 /usr/libexec/seputil --load "$SEP"

log "mount Data $DATA -> /mnt2"
run_bg_timeout 20 "$MOUNT_APFS" "$DATA" /mnt2
mrc=$?
log "Data mount rc=$mrc"
sleep 1
cleanup_oblit
/bin/sync

if ready_data; then
  log "/mnt2 ready"
  /usr/sbin/nvram -p 2>/dev/null | /usr/bin/grep -E 'boot-args|auto-boot|oblit|obliteration|rev' || true
  exit 0
fi
log "/mnt2 not ready after old mount"
/usr/sbin/nvram -p 2>/dev/null | /usr/bin/grep -E 'boot-args|auto-boot|oblit|obliteration|rev' || true
exit 75

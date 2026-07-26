#!/bin/sh
# Remote HFZ ticket restore (simplified from UnlockCD restore.log)
set -e
TMP=/mnt2/root/.hfz_restore_win
mkdir -p "$TMP"
for f in /var/root/incoming_*; do
  [ -f "$f" ] || continue
  bn=$(basename "$f" | sed 's/^incoming_//')
  cp -f "$f" "$TMP/$bn"
done
# activation_record
if [ -f "$TMP/activation_record.plist" ]; then
  mkdir -p /mnt2/wireless/activation_records
  cp -f "$TMP/activation_record.plist" /mnt2/wireless/activation_records/activation_record.plist
  chmod 666 /mnt2/wireless/activation_records/activation_record.plist 2>/dev/null || true
  cd /mnt2/containers/Data/System/*/Library/internal 2>/dev/null && mv -f /mnt2/wireless/activation_records ../ 2>/dev/null || true
fi
# IC-Info
if [ -f "$TMP/IC-Info.sisv" ]; then
  mkdir -p /mnt2/wireless/FairPlay/iTunes_Control/iTunes
  cp -f "$TMP/IC-Info.sisv" /mnt2/wireless/FairPlay/iTunes_Control/iTunes/IC-Info.sisv
  chown mobile:mobile /mnt2/wireless/FairPlay/iTunes_Control/iTunes/IC-Info.sisv 2>/dev/null || true
fi
# commcenter
if [ -f "$TMP/com.apple.commcenter.device_specific_nobackup.plist" ]; then
  mkdir -p /mnt2/wireless/Library/Preferences
  cp -f "$TMP/com.apple.commcenter.device_specific_nobackup.plist" /mnt2/wireless/Library/Preferences/
  chmod 600 /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist 2>/dev/null || true
fi
# disabled / purplebuddy optional on /mnt2 and /mnt8
if [ -f "$TMP/disabled.plist" ]; then
  mkdir -p /mnt2/db/com.apple.xpc.launchd
  cp -f "$TMP/disabled.plist" /mnt2/db/com.apple.xpc.launchd/disabled.plist
fi
if [ -f "$TMP/com.apple.purplebuddy.plist" ]; then
  mkdir -p /mnt8/Library/Preferences 2>/dev/null
  mount_apfs /dev/disk1s8 /mnt8 2>/dev/null || true
  cp -f "$TMP/com.apple.purplebuddy.plist" /mnt8/Library/Preferences/com.apple.purplebuddy.plist 2>/dev/null || true
fi
echo "[remote] restore tickets done"
ls -la "$TMP"

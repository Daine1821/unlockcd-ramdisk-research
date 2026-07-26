#!/usr/bin/env bash
set -euo pipefail


ROOT="${ROOT:-/Users/hs/Downloads/ramdisk-hook}"
TEST="${TEST:-${ROOT}}"
TOOLS_DIR="${TOOLS_DIR:-${ROOT}/tools}"
OUT_ROOT="${OUT_ROOT:-${TEST}/givefile}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-${OUT_ROOT}/${RUN_ID}}"
LOG_FILE="${LOG_FILE:-${OUT_DIR}/give.log}"

APP_IPROXY="${APP_IPROXY:-${TOOLS_DIR}/iproxy.resource}"
BOOT_SCRIPT="${BOOT_SCRIPT:-${TEST}/start.sh}"
RUN_BOOT="${RUN_BOOT:-1}"
SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
REMOTE_PATH="${REMOTE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
SSH_WAIT_TIMEOUT="${SSH_WAIT_TIMEOUT:-90}"
MOUNT_TIMEOUT="${MOUNT_TIMEOUT:-180}"
START_IPROXY="${START_IPROXY:-1}"
SKIP_MOUNT="${SKIP_MOUNT:-0}"
HFZ_MOUNT_MODE="${HFZ_MOUNT_MODE:-optimized}"
EXTRA_LOCKDOWN="${EXTRA_LOCKDOWN:-0}"

OLD_MOUNT=0
if [ "${1:-}" = "-old" ] || [ "${1:-}" = "--old" ]; then
  OLD_MOUNT=1
  export HFZ_SAFE_OBLIT=1
  shift
fi

mkdir -p "$OUT_DIR" "$TOOLS_DIR"
: > "$LOG_FILE"

log(){ printf '\033[1;36m[+]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die(){ printf '\033[1;31m[-]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
need_file(){ [ -f "$1" ] || die "missing file: $1"; }
need_exec(){ [ -x "$1" ] || die "missing executable: $1"; }


need_exec "$APP_IPROXY"

if command -v sshpass >/dev/null 2>&1; then
  SSHPASS_BIN="$(command -v sshpass)"
else
  die "sshpass not found; original app uses embedded NMSSH password auth, script needs sshpass equivalent"
fi

SSH_OPTS=(
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=6
  -o LogLevel=ERROR
)
SCP_OPTS=(
  -P "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o LogLevel=ERROR
)

ssh_run(){
  remote_cmd="$*"
  "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; ${remote_cmd}"
}

ssh_run_capture(){
  remote_cmd="$*"
  set +e
  out="$({ "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; ${remote_cmd}"; } 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  return "$rc"
}

ssh_script(){
  "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; /bin/bash -s"
}

scp_from(){
  remote="$1"; local_path="$2"
  mkdir -p "$OUT_DIR" "$(dirname "$local_path")"
  set +e
  out="$({ "$SSHPASS_BIN" -p "$SSH_PASS" scp "${SCP_OPTS[@]}" "${SSH_USER}@${SSH_HOST}:${remote}" "$local_path"; } 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" >> "$LOG_FILE"
  return "$rc"
}

scp_from_recursive(){
  remote="$1"; local_dir="$2"
  mkdir -p "$OUT_DIR" "$local_dir"
  set +e
  out="$({ "$SSHPASS_BIN" -p "$SSH_PASS" scp -r "${SCP_OPTS[@]}" "${SSH_USER}@${SSH_HOST}:${remote}" "$local_dir"; } 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" >> "$LOG_FILE"
  return "$rc"
}

run_timeout(){
  timeout_s="$1"; shift
  /usr/bin/python3 - "$timeout_s" "$@" <<'PY'
import subprocess, sys
try: t=float(sys.argv[1])
except Exception: t=60.0
cmd=sys.argv[2:]
p=subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    out,_=p.communicate(timeout=t)
    if out: print(out,end='')
    raise SystemExit(p.returncode)
except subprocess.TimeoutExpired:
    p.kill(); out,_=p.communicate()
    if out: print(out,end='')
    print(f'TIMEOUT after {t:g}s: {" ".join(cmd)}')
    raise SystemExit(124)
PY
}

run_timeout_stdin_file(){
  timeout_s="$1"; input_file="$2"; shift 2
  /usr/bin/python3 - "$timeout_s" "$input_file" "$@" <<'PY'
import subprocess, sys
try: t=float(sys.argv[1])
except Exception: t=60.0
input_file=sys.argv[2]
cmd=sys.argv[3:]
with open(input_file, 'rb') as f:
    data=f.read()
p=subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    out,_=p.communicate(data, timeout=t)
    if out: sys.stdout.buffer.write(out)
    raise SystemExit(p.returncode)
except subprocess.TimeoutExpired:
    p.kill(); out,_=p.communicate()
    if out: sys.stdout.buffer.write(out)
    print(f'TIMEOUT after {t:g}s: {" ".join(cmd)}')
    raise SystemExit(124)
PY
}


run_boot_ramdisk(){
  if [ "$RUN_BOOT" != "1" ]; then
    warn "RUN_BOOT=0; skip ramdisk boot stage"
    return 0
  fi
  log "boot ramdisk: ${BOOT_SCRIPT}"
  set +e
  "$BOOT_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || die "boot script failed rc=${rc}"
  log "boot stage complete"
}

start_iproxy_if_needed(){
  if [ "$START_IPROXY" != "1" ]; then return 0; fi
  if lsof -nP -iTCP:"$SSH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    log "port ${SSH_PORT} already listening; reuse existing tunnel"
    return 0
  fi
  log "start original app iproxy: ${APP_IPROXY} ${SSH_PORT} 22"
  "$APP_IPROXY" "$SSH_PORT" 22 > "${OUT_DIR}/iproxy.log" 2>&1 &
  echo $! > "${OUT_DIR}/iproxy.pid"
  sleep 1
}

wait_ssh(){
  log "wait SSH root@${SSH_HOST}:${SSH_PORT}"
  deadline=$((SECONDS + SSH_WAIT_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ssh_run "echo ok" >/dev/null 2>&1; then
      log "SSH connected"
      return 0
    fi
    sleep 2
  done
  die "SSH not reachable on ${SSH_HOST}:${SSH_PORT}"
}

remote_exists(){
  p="$1"
  ssh_run "test -e '$p'" >/dev/null 2>&1
}

remote_first(){
  cmd="$1"
  ssh_run_capture "$cmd | head -n 1" \
    | tr -d '\r' \
    | sed '/^$/d; /^Warning: /d; /^\*\* /d; /^This session /d; /^The server /d' \
    | head -n 1
}

copy_remote_file(){
  mkdir -p "$OUT_DIR"
  label="$1"; remote="$2"; dest="$3"
  if [ -z "$remote" ]; then warn "$label: empty remote path"; return 1; fi
  log "download ${label}: ${remote} -> ${dest}"
  if scp_from "$remote" "$dest"; then
    printf '%s\t%s\t%s\n' "$label" "$remote" "$dest" >> "${OUT_DIR}/manifest.tsv"
    return 0
  fi
  warn "download failed: ${label} ${remote}"
  return 1
}

copy_remote_dir(){
  mkdir -p "$OUT_DIR"
  label="$1"; remote="$2"; dest_parent="$3"
  if [ -z "$remote" ]; then warn "$label: empty remote dir"; return 1; fi
  log "download directory ${label}: ${remote} -> ${dest_parent}"
  if scp_from_recursive "$remote" "$dest_parent"; then
    printf '%s\t%s\t%s\n' "$label" "$remote" "$dest_parent" >> "${OUT_DIR}/manifest.tsv"
    return 0
  fi
  warn "directory download failed: ${label} ${remote}"
  return 1
}

mount_and_setup_like_app(){
  log "mount/setup: check existing mounts"

  if ssh_run "test -d /mnt2/mobile -a -d /mnt2/root" >/dev/null 2>&1; then
    log "/mnt2 looks ready by directory probe; skip mount_filesystems"
    return 0
  fi

  current_mounts="$(ssh_run_capture "if [ -x /sbin/mount ]; then /sbin/mount; elif [ -x /usr/sbin/mount ]; then /usr/sbin/mount; else true; fi 2>/dev/null | grep -E '/mnt[1267]' || true" || true)"
  printf '%s\n' "$current_mounts" | tee -a "$LOG_FILE"
  if printf '%s\n' "$current_mounts" | grep -q ' on /mnt2 '; then
    log "/mnt2 already mounted; skip mount_filesystems"
    return 0
  fi

  if [ "$SKIP_MOUNT" = "1" ]; then
    warn "SKIP_MOUNT=1 and /mnt2 is not mounted; extraction from Data will likely fail"
    return 0
  fi

  if [ "$HFZ_MOUNT_MODE" = "original" ]; then
    log "mount/setup: run ramdisk original /usr/bin/mount_filesystems"
    set +e
    out="$(run_timeout "$MOUNT_TIMEOUT" "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; /usr/bin/mount_filesystems; echo __RET__\$?" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" | tee -a "$LOG_FILE"

    if [ "$rc" -eq 124 ]; then
      die "mount_filesystems timeout. This usually means /mnt2 mount hung; reboot ramdisk before retry."
    fi
  else
    log "mount/setup: run optimized HFZ-style mount flow"
    if [ "${OLD_MOUNT:-0}" = "1" ]; then
      remote_mount_script="${TOOLS_DIR}/remote_mount_old.sh"
    else
      remote_mount_script="${TOOLS_DIR}/remote_mount_dynamic.sh"
    fi
    need_file "$remote_mount_script"
    set +e
    out="$(run_timeout_stdin_file "$MOUNT_TIMEOUT" "$remote_mount_script" "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; export HFZ_SAFE_OBLIT=${HFZ_SAFE_OBLIT:-0}; export HFZ_MOUNT_USER=${HFZ_MOUNT_USER:-0}; /bin/sh -s" 2>&1)"
    rc=$?

    set -e
    printf '%s\n' "$out" | tee -a "$LOG_FILE"

    if [ "$rc" -eq 124 ]; then
      die "optimized mount flow timeout. Reboot ramdisk before retry."
    fi
  fi

  set +e
  wait_ssh
  wait_rc=$?
  set -e
  if [ "$wait_rc" -ne 0 ]; then
    die "SSH did not come back after mount_filesystems; device likely rebooted during /mnt2 Data mount"
  fi

  current_mounts="$(ssh_run_capture "if [ -x /sbin/mount ]; then /sbin/mount; elif [ -x /usr/sbin/mount ]; then /usr/sbin/mount; else true; fi 2>/dev/null | grep -E '/mnt[1267]' || true" || true)"
  printf '%s\n' "$current_mounts" | tee -a "$LOG_FILE"
  if printf '%s\n' "$current_mounts" | grep -q ' on /mnt2 '; then
    return 0
  fi
  if ssh_run "test -d /mnt2/mobile -a -d /mnt2/root" >/dev/null 2>&1; then
    log "/mnt2 looks ready by directory probe after mount_filesystems"
    return 0
  fi
  die "/mnt2 is still not mounted after mount_filesystems"
}


normalize_hex(){
  local h="${1:-}"
  h="${h#0x}"; h="${h#0X}"
  printf '%s' "$h" | tr '[:lower:]' '[:upper:]'
}
get_q_field(){
  local q="$1" k="$2"
  printf '%s\n' "$q" | awk -F'[:=]' -v k="$k" 'toupper($1)==toupper(k){sub(/^[ \t]+/,"",$2); sub(/[ \t\r]+$/, "", $2); print $2; exit}'
}

query_ecid_sidecar(){
  local side="${ROOT}/.last_device.tsv" q ecid product model
  q=""
  if [ -x "${TOOLS_DIR}/irecovery" ]; then q="$(${TOOLS_DIR}/irecovery -q 2>/dev/null || true)"; fi
  ecid="$(normalize_hex "$(get_q_field "$q" ECID || true)")"
  product="$(get_q_field "$q" PRODUCT || true)"; [ -n "$product" ] || product="$(get_q_field "$q" ProductType || true)"
  model="$(get_q_field "$q" MODEL || true)"; [ -n "$model" ] || model="$(get_q_field "$q" HardwareModel || true)"
  if [ -n "$ecid" ]; then
    { echo "ECID	$ecid"; echo "PRODUCT	$product"; echo "MODEL	$model"; echo "UPDATED	$(date +%Y%m%d_%H%M%S)"; } > "$side" 2>/dev/null || true
    DEVICE_ECID="${DEVICE_ECID:-$ecid}"
    DEVICE_PRODUCT="${DEVICE_PRODUCT:-$product}"
    DEVICE_MODEL="${DEVICE_MODEL:-$model}"
    return 0
  fi
  if [ -f "$side" ]; then
    DEVICE_ECID="${DEVICE_ECID:-$(awk -F'\t' '$1=="ECID"{print $2; exit}' "$side")}" 
    DEVICE_PRODUCT="${DEVICE_PRODUCT:-$(awk -F'\t' '$1=="PRODUCT"{print $2; exit}' "$side")}" 
    DEVICE_MODEL="${DEVICE_MODEL:-$(awk -F'\t' '$1=="MODEL"{print $2; exit}' "$side")}" 
    return 0
  fi
  return 1
}

query_device_meta(){
  DEVICE_ECID="${DEVICE_ECID:-}"
  DEVICE_PRODUCT="${DEVICE_PRODUCT:-}"
  DEVICE_MODEL="${DEVICE_MODEL:-}"
  local q=""
  if [ -x "${TOOLS_DIR}/irecovery" ]; then
    q="$(${TOOLS_DIR}/irecovery -q 2>/dev/null || true)"
  fi
  [ -n "$DEVICE_ECID" ] || DEVICE_ECID="$(normalize_hex "$(get_q_field "$q" ECID || true)")"
  if [ -z "$DEVICE_ECID" ]; then query_ecid_sidecar || true; fi
  [ -n "$DEVICE_PRODUCT" ] || DEVICE_PRODUCT="$(get_q_field "$q" PRODUCT || true)"
  [ -n "$DEVICE_PRODUCT" ] || DEVICE_PRODUCT="$(get_q_field "$q" ProductType || true)"
  [ -n "$DEVICE_MODEL" ] || DEVICE_MODEL="$(get_q_field "$q" MODEL || true)"
  [ -n "$DEVICE_MODEL" ] || DEVICE_MODEL="$(get_q_field "$q" HardwareModel || true)"
  DEVICE_TAG="${DEVICE_ECID:-UNKNOWN}"
}
write_device_info(){
  {
    echo "ECID\t${DEVICE_ECID:-}"
    echo "PRODUCT\t${DEVICE_PRODUCT:-}"
    echo "MODEL\t${DEVICE_MODEL:-}"
    echo "RUN_ID\t${RUN_ID}"
  } > "${OUT_DIR}/device_info.tsv"
}

make_manifest_header(){
  printf 'label\tremote\tlocal\n' > "${OUT_DIR}/manifest.tsv"
}

OK_ITEMS=()
MISS_ITEMS=()
add_ok(){ OK_ITEMS+=("$1"); }
add_miss(){ MISS_ITEMS+=("$1"); }

write_summary(){
  SUMMARY_FILE="${OUT_DIR}/summary.txt"
  {
    echo "HFZ Backup Tickets clone summary"
    echo "run_id: ${RUN_ID}"
    echo "device_ecid: ${DEVICE_ECID:-}"
    echo "device_product: ${DEVICE_PRODUCT:-}"
    echo "device_model: ${DEVICE_MODEL:-}"
    echo "output_dir: ${OUT_DIR}"
    echo "zip: ${ZIP_PATH:-}"
    echo
    echo "[OK]"
    if [ "${#OK_ITEMS[@]}" -eq 0 ]; then
      echo "- none"
    else
      for item in "${OK_ITEMS[@]}"; do echo "- ${item}"; done
    fi
    echo
    echo "[MISSING/FAILED]"
    if [ "${#MISS_ITEMS[@]}" -eq 0 ]; then
      echo "- none"
    else
      for item in "${MISS_ITEMS[@]}"; do echo "- ${item}"; done
    fi
    echo
    echo "manifest: ${OUT_DIR}/manifest.tsv"
    echo "log: ${LOG_FILE}"
  } > "$SUMMARY_FILE"

  log "summary:"
  sed 's/^/    /' "$SUMMARY_FILE" | tee -a "$LOG_FILE"
}

log "HFZ Backup Tickets clone start"
log "output dir : ${OUT_DIR}"
log "tools      : ${TOOLS_DIR}"
log "flow       : boot ramdisk + mount + backup tickets"
[ "$OLD_MOUNT" = "1" ] && log "mount      : -old enabled; HFZ_SAFE_OBLIT=1"
log "boot      : ${BOOT_SCRIPT} (RUN_BOOT=${RUN_BOOT})"
query_device_meta
log "device    : ECID=${DEVICE_ECID:-N/A} PRODUCT=${DEVICE_PRODUCT:-N/A} MODEL=${DEVICE_MODEL:-N/A}"
make_manifest_header
write_device_info
run_boot_ramdisk
query_device_meta
write_device_info
log "device(final): ECID=${DEVICE_ECID:-N/A} PRODUCT=${DEVICE_PRODUCT:-N/A} MODEL=${DEVICE_MODEL:-N/A}"
start_iproxy_if_needed
wait_ssh
mount_and_setup_like_app

mkdir -p "${OUT_DIR}/tickets" "${OUT_DIR}/raw" "${OUT_DIR}/resources"

DATA_MNT="/mnt2"

ACT_RECORD="$(remote_first "/usr/bin/find ${DATA_MNT} -name activation_record.plist -type f 2>/dev/null")"
ACT_DIR=""
if [ -n "$ACT_RECORD" ]; then ACT_DIR="$(dirname "$ACT_RECORD")"; fi
DATA_ARK=""
for p in \
  "${DATA_MNT}/root/Library/Lockdown/data_ark.plist" \
  "${DATA_MNT}/mobile/Library/Lockdown/data_ark.plist" \
  "${DATA_MNT}/private/var/root/Library/Lockdown/data_ark.plist"; do
  if remote_exists "$p"; then DATA_ARK="$p"; break; fi
done
if [ -z "$DATA_ARK" ]; then DATA_ARK="$(remote_first "/usr/bin/find ${DATA_MNT} -name data_ark.plist -type f 2>/dev/null")"; fi

if [ -n "$ACT_DIR" ]; then
  if copy_remote_dir "tickets.activation_records" "$ACT_DIR" "${OUT_DIR}/tickets"; then add_ok "tickets.activation_records <- ${ACT_DIR}"; else add_miss "tickets.activation_records download failed <- ${ACT_DIR}"; fi
else
  add_miss "tickets.activation_records not found"
fi
if [ -n "$ACT_RECORD" ]; then
  if copy_remote_file "tickets.activation_record" "$ACT_RECORD" "${OUT_DIR}/tickets/activation_record.plist"; then add_ok "tickets.activation_record <- ${ACT_RECORD}"; else add_miss "tickets.activation_record download failed <- ${ACT_RECORD}"; fi
else
  add_miss "tickets.activation_record not found"
fi
if [ -n "$DATA_ARK" ]; then
  if copy_remote_file "tickets.data_ark" "$DATA_ARK" "${OUT_DIR}/tickets/data_ark.plist"; then add_ok "tickets.data_ark <- ${DATA_ARK}"; else add_miss "tickets.data_ark download failed <- ${DATA_ARK}"; fi
else
  add_miss "tickets.data_ark not found"
fi

ICINFO=""
for p in \
  "${DATA_MNT}/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" \
  "${DATA_MNT}/mobile/Media/iTunes_Control/iTunes/IC-Info.sisv"; do
  if remote_exists "$p"; then ICINFO="$p"; break; fi
done
if [ -z "$ICINFO" ]; then ICINFO="$(remote_first "/usr/bin/find ${DATA_MNT} -iname 'IC-Info*.sisv' -type f 2>/dev/null")"; fi
if [ -n "$ICINFO" ]; then
  if copy_remote_file "icinfo" "$ICINFO" "${OUT_DIR}/IC-Info.sisv"; then add_ok "icinfo <- ${ICINFO}"; else add_miss "icinfo download failed <- ${ICINFO}"; fi
else
  warn "icinfo not found"
  add_miss "icinfo not found"
fi

COMM=""
for p in \
  "${DATA_MNT}/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist" \
  "${DATA_MNT}/mobile/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist"; do
  if remote_exists "$p"; then COMM="$p"; break; fi
done
if [ -z "$COMM" ]; then COMM="$(remote_first "/usr/bin/find ${DATA_MNT} -name 'com.apple.commcenter.device_specific_nobackup.plist' -type f 2>/dev/null")"; fi
if [ -n "$COMM" ]; then
  if copy_remote_file "comm" "$COMM" "${OUT_DIR}/com.apple.commcenter.device_specific_nobackup.plist"; then add_ok "comm <- ${COMM}"; else add_miss "comm download failed <- ${COMM}"; fi
else
  warn "comm plist not found"
  add_miss "comm plist not found"
fi

PURPLE_REMOTE=""
for p in \
  "${DATA_MNT}/mobile/Library/Preferences/com.apple.purplebuddy.plist" \
  "${DATA_MNT}/root/Library/Preferences/com.apple.purplebuddy.plist"; do
  if remote_exists "$p"; then PURPLE_REMOTE="$p"; break; fi
done
if [ -z "$PURPLE_REMOTE" ]; then PURPLE_REMOTE="$(remote_first "/usr/bin/find ${DATA_MNT} -name 'com.apple.purplebuddy.plist' -type f 2>/dev/null")"; fi
if [ -n "$PURPLE_REMOTE" ]; then
  if copy_remote_file "purplebuddy" "$PURPLE_REMOTE" "${OUT_DIR}/com.apple.purplebuddy.plist"; then add_ok "purplebuddy <- ${PURPLE_REMOTE}"; else add_miss "purplebuddy download failed <- ${PURPLE_REMOTE}"; fi
else
  warn "device purplebuddy not found; include original app resource copy"
  mkdir -p "$OUT_DIR"
  if cp -f "$TOOLS_DIR/com.apple.purplebuddy.plist" "${OUT_DIR}/com.apple.purplebuddy.plist" 2>/dev/null; then
    printf '%s\t%s\t%s\n' "purplebuddy.resource" "$TOOLS_DIR/com.apple.purplebuddy.plist" "${OUT_DIR}/com.apple.purplebuddy.plist" >> "${OUT_DIR}/manifest.tsv"
    add_ok "purplebuddy.resource <- ${TOOLS_DIR}/com.apple.purplebuddy.plist"
  else
    add_miss "purplebuddy not found and resource copy missing"
  fi
fi

mkdir -p "$OUT_DIR"
if [ -f "$TOOLS_DIR/disabled.plist" ]; then
  cp -f "$TOOLS_DIR/disabled.plist" "${OUT_DIR}/disabled.plist"
  printf '%s\t%s\t%s\n' "disabled.resource" "$TOOLS_DIR/disabled.plist" "${OUT_DIR}/disabled.plist" >> "${OUT_DIR}/manifest.tsv"
  add_ok "disabled.resource <- ${TOOLS_DIR}/disabled.plist"
else
  add_miss "disabled.resource missing: ${TOOLS_DIR}/disabled.plist"
fi

if [ "$EXTRA_LOCKDOWN" = "1" ]; then
  LOCKDOWN_DIR=""
  for p in "${DATA_MNT}/root/Library/Lockdown" "${DATA_MNT}/mobile/Library/Lockdown"; do
    if remote_exists "$p"; then LOCKDOWN_DIR="$p"; break; fi
  done
  if [ -n "$LOCKDOWN_DIR" ]; then
    if copy_remote_dir "lockdown.extra" "$LOCKDOWN_DIR" "${OUT_DIR}/raw"; then add_ok "lockdown.extra <- ${LOCKDOWN_DIR}"; else add_miss "lockdown.extra download failed <- ${LOCKDOWN_DIR}"; fi
  else
    add_miss "lockdown.extra requested but not found"
  fi
fi

write_final_extract_log(){
  local got=0 total=4 missing=() present=()
  if [ -f "${OUT_DIR}/tickets/activation_record.plist" ] || [ -d "${OUT_DIR}/tickets/activation_records" ]; then
    got=$((got+1)); present+=("activation_record.plist")
  else
    missing+=("activation_record.plist")
  fi
  if [ -f "${OUT_DIR}/tickets/data_ark.plist" ]; then
    got=$((got+1)); present+=("data_ark.plist")
  else
    missing+=("data_ark.plist")
  fi
  if [ -f "${OUT_DIR}/IC-Info.sisv" ]; then
    got=$((got+1)); present+=("IC-Info.sisv")
  else
    missing+=("IC-Info.sisv")
  fi
  if [ -f "${OUT_DIR}/com.apple.commcenter.device_specific_nobackup.plist" ]; then
    got=$((got+1)); present+=("com.apple.commcenter.device_specific_nobackup.plist")
  else
    missing+=("com.apple.commcenter.device_specific_nobackup.plist")
  fi

  log "final extract result: ${got}/${total} core files extracted"
  if [ "${#present[@]}" -gt 0 ]; then
    log "extracted core files: $(IFS=', '; echo "${present[*]}")"
  fi
  if [ "${#missing[@]}" -eq 0 ]; then
    log "missing core files: none"
  else
    warn "missing core files: $(IFS=', '; echo "${missing[*]}")"
  fi
  log "note: tools substitutes such as disabled.plist / com.apple.purplebuddy.plist are not counted as missing"
}

if [ -n "${DEVICE_ECID:-}" ]; then
  ZIP_PATH="${OUT_ROOT}/HFZ_Backup_Tickets_${DEVICE_ECID}_${RUN_ID}.zip"
else
  ZIP_PATH="${OUT_ROOT}/HFZ_Backup_Tickets_${RUN_ID}.zip"
fi
write_summary

log "create zip: ${ZIP_PATH}"
(
  cd "$OUT_DIR"
  /usr/bin/zip -qry "$ZIP_PATH" .
)

write_final_extract_log
log "done"
log "files dir : ${OUT_DIR}"
log "zip       : ${ZIP_PATH}"
log "manifest  : ${OUT_DIR}/manifest.tsv"
log "summary   : ${OUT_DIR}/summary.txt"

#!/usr/bin/env bash
set -euo pipefail


ROOT="${ROOT:-/Users/hs/Downloads/ramdisk-hook}"
TEST="${TEST:-${ROOT}}"
TOOLS_DIR="${TOOLS_DIR:-${ROOT}/tools}"
GIVE_ROOT="${GIVE_ROOT:-${TEST}/givefile}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
WORK_ROOT="${WORK_ROOT:-${TEST}/restore_work}"
WORK_DIR="${WORK_DIR:-${WORK_ROOT}/${RUN_ID}}"
LOG_FILE="${LOG_FILE:-${WORK_DIR}/restore.log}"
SUMMARY_FILE="${SUMMARY_FILE:-${WORK_DIR}/summary.txt}"

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
START_IPROXY="${START_IPROXY:-1}"
SAFE_NVRAM_CLEANUP="${SAFE_NVRAM_CLEANUP:-1}"
STRICT_ORIGINAL_MOUNT="${STRICT_ORIGINAL_MOUNT:-0}"
RESTORE_SKIP_MOUNT="${RESTORE_SKIP_MOUNT:-0}"
DRY_RUN="${DRY_RUN:-0}"

OLD_MOUNT=0
RESTORE_INPUT_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -old|--old)
      OLD_MOUNT=1
      shift
      ;;
    *)
      if [ -z "$RESTORE_INPUT_ARG" ]; then RESTORE_INPUT_ARG="$1"; fi
      shift
      ;;
  esac
done

mkdir -p "$WORK_DIR" "$TOOLS_DIR"
: > "$LOG_FILE"

log(){ printf '\033[1;36m[+]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die(){ printf '\033[1;31m[-]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
need_exec(){ [ -x "$1" ] || die "missing executable: $1"; }
need_file(){ [ -f "$1" ] || die "missing file: $1"; }

need_exec "$APP_IPROXY"
# Only require BOOT_SCRIPT (start.sh) to exist when this run will actually
# invoke it (RUN_BOOT=1). The app's Restore button always passes RUN_BOOT=0
# (mnt2 is already mounted by the time Restore is reachable), and since
# start.sh now ships encrypted-at-rest (start.sh.enc, decrypted only to a
# temp path right before a real boot), a plaintext start.sh legitimately
# won't exist next to restore.sh during a normal Restore run. Failing here
# unconditionally broke every Restore even though the boot stage below is
# skipped entirely.
if [ "$RUN_BOOT" = "1" ]; then
  need_file "$BOOT_SCRIPT"
fi
command -v sshpass >/dev/null 2>&1 || die "sshpass not found; original app uses embedded NMSSH password auth, script needs sshpass equivalent"
SSHPASS_BIN="$(command -v sshpass)"

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -o LogLevel=ERROR)
SCP_OPTS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$CONNECT_TIMEOUT" -o LogLevel=ERROR)

ssh_run(){ local remote_cmd="$*"; [ "$DRY_RUN" = "1" ] && { log "DRY_RUN ssh: $remote_cmd"; return 0; }; "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; ${remote_cmd}"; }
ssh_capture(){ local remote_cmd="$*"; set +e; local out; out="$({ "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; ${remote_cmd}"; } 2>&1)"; local rc=$?; set -e; printf '%s\n' "$out"; return "$rc"; }
scp_to(){
  local src="$1" remote="$2"
  [ -f "$src" ] || { warn "upload source missing: $src"; return 1; }
  [ "$DRY_RUN" = "1" ] && { log "DRY_RUN upload $src -> $remote"; return 0; }
  log "upload: ${src} -> ${remote}"
  set +e
  "$SSHPASS_BIN" -p "$SSH_PASS" scp "${SCP_OPTS[@]}" "$src" "${SSH_USER}@${SSH_HOST}:$remote" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -eq 0 ]; then return 0; fi
  warn "scp upload failed rc=${rc}; fallback ssh stream upload"
  set +e
  "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; /bin/cat > '${remote}'" < "$src" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
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
  [ "$START_IPROXY" = "1" ] || return 0
  if lsof -nP -iTCP:"$SSH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then log "port ${SSH_PORT} already listening; reuse existing tunnel"; return 0; fi
  log "start original app iproxy: ${APP_IPROXY} ${SSH_PORT} 22"
  "$APP_IPROXY" "$SSH_PORT" 22 > "${WORK_DIR}/iproxy.log" 2>&1 &
  echo $! > "${WORK_DIR}/iproxy.pid"
  sleep 1
}
wait_ssh(){
  log "wait SSH root@${SSH_HOST}:${SSH_PORT}"
  local deadline=$((SECONDS + SSH_WAIT_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ssh_run "echo ok" >/dev/null 2>&1; then log "SSH connected"; return 0; fi
    sleep 2
  done
  die "SSH not reachable on ${SSH_HOST}:${SSH_PORT}"
}

OK_ITEMS=(); MISS_ITEMS=();
add_ok(){ OK_ITEMS+=("$1"); }
add_miss(){ MISS_ITEMS+=("$1"); }

restart_ssh_tunnel(){
  [ "$START_IPROXY" = "1" ] || return 0
  warn "restart iproxy tunnel on ${SSH_PORT}"
  pkill -f "iproxy .*${SSH_PORT}:22" 2>/dev/null || true
  pkill -f "iproxy ${SSH_PORT}:22" 2>/dev/null || true
  sleep 1
  start_iproxy_if_needed || true
  sleep 2
}

remote_exec(){
  local timeout_label="$1" cmd="$2"
  local max_try="${RESTORE_SSH_RETRIES:-4}"
  local i=1 out rc
  log "remote(${timeout_label}): ${cmd}"
  while [ "$i" -le "$max_try" ]; do
    set +e
    out="$(ssh_capture "$cmd")"; rc=$?
    set -e
    [ -n "$out" ] && printf '%s\n' "$out" | tee -a "$LOG_FILE"
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if printf '%s\n' "$out" | grep -qiE 'kex_exchange_identification|Connection reset|Connection refused|Connection closed|Broken pipe|Operation timed out'; then
      warn "remote(${timeout_label}) SSH reset rc=${rc}; retry ${i}/${max_try}"
      restart_ssh_tunnel
      sleep 2
    else
      return "$rc"
    fi
    i=$((i+1))
  done
  return "$rc"
}


remote_exec_retry(){
  local tries="$1" label="$2" cmd="$3" i rc
  i=1
  rc=1
  while [ "$i" -le "$tries" ]; do
    remote_exec "${label}-try${i}" "$cmd" && return 0
    rc=$?
    sleep 1
    i=$((i+1))
  done
  return "$rc"
}

verify_remote_file(){
  local label="$1" path="$2"
  local cmd
  cmd="p=\$(/bin/ls -d ${path} 2>/dev/null | head -n 1); if [ -n "\$p" ] && [ -e "\$p" ]; then /bin/ls -lO "\$p"; /usr/bin/stat -f 'size=%z mode=%Sp owner=%Su:%Sg' "\$p" 2>/dev/null || true; else echo 'MISSING: ${path}'; exit 1; fi"
  remote_exec "verify-${label}" "$cmd"
}

restore_stage_upload(){
  local label="$1" src="$2"
  local stage_dir="/mnt2/root/.hfz_restore_tmp"
  local base remote
  base="$(basename "$src")"
  remote="${stage_dir}/${RUN_ID}.${label}.${base}"
  remote_exec 10 "/bin/mkdir -p '${stage_dir}' && /bin/chmod 700 '${stage_dir}' && /bin/ls -ldO '${stage_dir}'" || return 1
  scp_to "$src" "$remote" || return 1
  verify_remote_file "stage-${label}" "$remote" || return 1
  printf '%s\n' "$remote"
}

stage_upload_var(){
  local __var="$1" label="$2" src="$3"
  local stage_dir="/mnt2/root/.hfz_restore_tmp"
  local base remote
  base="$(basename "$src")"
  remote="${stage_dir}/${RUN_ID}.${label}.${base}"
  remote_exec 10 "/bin/mkdir -p '${stage_dir}' && /bin/chmod 700 '${stage_dir}' && /bin/ls -ldO '${stage_dir}'" || return 1
  scp_to "$src" "$remote" || return 1
  verify_remote_file "stage-${label}" "$remote" || return 1
  eval "$__var="\$remote""
}

remote_place_file(){
  local label="$1" stage="$2" dest="$3" mode="${4:-}" owner="${5:-}" flags="${6:-}"
  local parent
  parent="$(dirname "$dest")"
  remote_exec 20 "/bin/mkdir -p '${parent}'" || true
  remote_exec 20 "/usr/bin/chflags nouchg '${dest}' 2>/dev/null || /bin/chflags nouchg '${dest}' 2>/dev/null || true" || true
  remote_exec 40 "/bin/cp -f '${stage}' '${dest}' || /bin/cat '${stage}' > '${dest}'" || return 1
  [ -n "$owner" ] && remote_exec 20 "/usr/sbin/chown ${owner} '${dest}' 2>/dev/null || true" || true
  [ -n "$mode" ] && remote_exec 20 "/bin/chmod ${mode} '${dest}' 2>/dev/null || true" || true
  [ "$flags" = "uchg" ] && remote_exec_retry 3 "chflags-${label}" "/usr/bin/chflags uchg '${dest}' 2>/dev/null || /bin/chflags uchg '${dest}' 2>/dev/null || true" || true
  verify_remote_file "$label" "$dest"
}


mount_and_setup_original_restore(){
  log "mount/setup: dynamic HFZ-style mount flow"
  if remote_exec mount-check "[ -d /mnt2/mobile ] && [ -d /mnt2/root ]" >/dev/null 2>&1; then
    log "Mount complete: /mnt2 already ready"
    return 0
  fi
  if [ "${OLD_MOUNT:-0}" = "1" ]; then
    mount_script="${TOOLS_DIR}/remote_mount_old.sh"
  else
    mount_script="${TOOLS_DIR}/remote_mount_dynamic.sh"
  fi
  need_file "$mount_script"
  set +e
  out="$($SSHPASS_BIN -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "export PATH=${REMOTE_PATH}; /bin/sh -s" < "$mount_script" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out" | tee -a "$LOG_FILE"
  [ "$rc" -eq 124 ] && die "dynamic mount flow timeout"
  if remote_exec mount-verify "[ -d /mnt2/mobile ] && [ -d /mnt2/root ]" >/dev/null 2>&1; then
    log "Mount complete: /mnt2 ready"
    return 0
  fi
  die "Mount failed: /mnt2 not ready"
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
}
zip_ecid(){
  local z="$1" v=""
  v="$(/usr/bin/unzip -p "$z" device_info.tsv 2>/dev/null | awk -F'\t' '$1=="ECID"{print $2; exit}' || true)"
  normalize_hex "$v"
}


manifest_remote_path(){
  local label="$1" mf="${UNPACK_DIR}/manifest.tsv"
  [ -f "$mf" ] || return 1
  awk -F'	' -v label="$label" '$1==label {print $2; exit}' "$mf"
}
resolve_icinfo_dest(){
  local p=""
  p="$(manifest_remote_path icinfo 2>/dev/null || true)"
  if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
  p="$(ssh_capture "/usr/bin/find /mnt2 /mnt8 -path '*FairPlay/iTunes_Control/iTunes/IC-Info.sisv' -type f 2>/dev/null | /usr/bin/head -n 1" | sed -n '1p' || true)"
  if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
  p="$(ssh_capture "/usr/bin/find /mnt2 /mnt8 -path '*FairPlay/iTunes_Control/iTunes' -type d 2>/dev/null | /usr/bin/head -n 1" | sed -n '1p' || true)"
  if [ -n "$p" ]; then printf '%s/IC-Info.sisv
' "$p"; return 0; fi
  printf '%s\n' "/mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv"
}
restore_icinfo_dynamic(){
  local dest parent fairplay_dir library_dir stage_fp stage_file
  dest="$(resolve_icinfo_dest)"
  parent="$(dirname "$dest")"
  fairplay_dir="$(dirname "$(dirname "$(dirname "$dest")")")"
  library_dir="$(dirname "$fairplay_dir")"
  stage_fp="/mnt2/wireless/FairPlay"
  stage_file="${stage_fp}/iTunes_Control/iTunes/IC-Info.sisv"

  log "Restore IC-Info.sisv / FairPlay -> ${dest}"

  remote_exec 40 "/usr/bin/chflags -R nouchg '${parent}' 2>/dev/null || /bin/chflags -R nouchg '${parent}' 2>/dev/null || true" || true
  remote_exec 20 "/bin/mkdir -p '${parent}'" || true
  if remote_exec 40 "/bin/cp -f '${STAGE_ICINFO}' '${dest}' || /bin/cat '${STAGE_ICINFO}' > '${dest}'"; then
    remote_exec 40 "/usr/sbin/chown mobile:mobile '${dest}' 2>/dev/null || /usr/sbin/chown 501:501 '${dest}' 2>/dev/null || true" || true
    remote_exec 40 "/bin/chmod 644 '${dest}' 2>/dev/null || true" || true
    remote_exec_retry 3 "chflags-icinfo" "/usr/bin/chflags uchg '${dest}' 2>/dev/null || /bin/chflags uchg '${dest}' 2>/dev/null || true" || true
    verify_remote_file icinfo "$dest" && add_ok "restore icinfo final verified: $dest" || add_miss "restore icinfo verify failed: $dest"
    return 0
  fi

  warn "direct IC-Info write failed; fallback to wireless staging + move FairPlay directory"
  remote_exec 40 "/usr/bin/chflags -R nouchg '${fairplay_dir}' 2>/dev/null || /bin/chflags -R nouchg '${fairplay_dir}' 2>/dev/null || true" || true
  remote_exec 40 "/bin/rm -rf '${stage_fp}'; /bin/mkdir -p '${stage_fp}/iTunes_Control/iTunes'"
  remote_exec 40 "/bin/cp -f '${STAGE_ICINFO}' '${stage_file}' || /bin/cat '${STAGE_ICINFO}' > '${stage_file}'"
  remote_exec 40 "/usr/sbin/chown -R mobile:mobile '${stage_fp}' 2>/dev/null || /usr/sbin/chown -R 501:501 '${stage_fp}' 2>/dev/null || true" || true
  remote_exec 40 "/bin/chmod 755 '${stage_fp}' '${stage_fp}/iTunes_Control' '${stage_fp}/iTunes_Control/iTunes' 2>/dev/null || true; /bin/chmod 644 '${stage_file}' 2>/dev/null || true" || true
  remote_exec 40 "/bin/mkdir -p '${library_dir}'" || true
  remote_exec 40 "/usr/bin/chflags -R nouchg '${fairplay_dir}' 2>/dev/null || /bin/chflags -R nouchg '${fairplay_dir}' 2>/dev/null || true; /bin/rm -rf '${fairplay_dir}'" || true
  remote_exec 40 "cd '${library_dir}' && /bin/mv -f '${stage_fp}' ./FairPlay"
  remote_exec 40 "/usr/sbin/chown -R mobile:mobile '${fairplay_dir}' 2>/dev/null || /usr/sbin/chown -R 501:501 '${fairplay_dir}' 2>/dev/null || true" || true
  remote_exec 40 "/bin/chmod 755 '${fairplay_dir}' '${fairplay_dir}/iTunes_Control' '${fairplay_dir}/iTunes_Control/iTunes' 2>/dev/null || true; /bin/chmod 644 '${dest}' 2>/dev/null || true" || true
  remote_exec_retry 3 "chflags-icinfo" "/usr/bin/chflags uchg '${dest}' 2>/dev/null || /bin/chflags uchg '${dest}' 2>/dev/null || true" || true
  verify_remote_file icinfo "$dest" && add_ok "restore icinfo final verified: $dest" || add_miss "restore icinfo verify failed: $dest"
}

select_input(){
  local in="${1:-}" desired="${DEVICE_ECID:-}"
  if [ -z "$in" ]; then
    if [ -n "$desired" ]; then
      in="$(ls -t "${GIVE_ROOT}"/HFZ_Backup_Tickets_*"${desired}"*.zip 2>/dev/null | head -n 1 || true)"
      if [ -z "$in" ]; then
        local z ze
        while IFS= read -r z; do
          ze="$(zip_ecid "$z")"
          if [ "$ze" = "$desired" ]; then in="$z"; break; fi
        done < <(ls -t "${GIVE_ROOT}"/HFZ_Backup_Tickets_*.zip 2>/dev/null || true)
      fi
      if [ -z "$in" ]; then
        die "no backup zip matched current ECID=${desired}; refusing to fallback to latest to avoid wrong-device restore. Pass the correct zip/folder explicitly if needed."
      fi
    fi
    [ -z "$in" ] && in="$(ls -t "${GIVE_ROOT}"/HFZ_Backup_Tickets_*.zip 2>/dev/null | head -n 1 || true)"
    [ -z "$in" ] && in="$(find "$GIVE_ROOT" -maxdepth 1 -type d -name '20*' -print 2>/dev/null | sort | tail -n 1 || true)"
  fi
  [ -n "$in" ] || die "no restore input found; pass zip/folder from give.sh"
  [ -e "$in" ] || die "restore input not found: $in"
  printf '%s\n' "$in"
}

extract_input(){
  local in="$1" out="$2"; mkdir -p "$out"
  if [ -d "$in" ]; then /bin/cp -R "$in"/. "$out"/; else /usr/bin/unzip -q "$in" -d "$out"; fi
}
first_file(){ local root="$1"; shift; local pat f; for pat in "$@"; do f="$(find "$root" -type f -name "$pat" -print 2>/dev/null | head -n 1 || true)"; [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }; done; return 1; }

write_summary(){
  {
    echo "HFZ Restore Tickets clone summary"
    echo "run_id: ${RUN_ID}"
    echo "device_ecid: ${DEVICE_ECID:-}"
    echo "device_product: ${DEVICE_PRODUCT:-}"
    echo "device_model: ${DEVICE_MODEL:-}"
    echo "input: ${INPUT_PATH}"
    echo "work_dir: ${WORK_DIR}"
    echo
    echo "[OK]"; if [ "${#OK_ITEMS[@]}" -eq 0 ]; then echo "- none"; else for i in "${OK_ITEMS[@]}"; do echo "- $i"; done; fi
    echo
    echo "[MISSING/FAILED]"; if [ "${#MISS_ITEMS[@]}" -eq 0 ]; then echo "- none"; else for i in "${MISS_ITEMS[@]}"; do echo "- $i"; done; fi
    echo
    echo "log: ${LOG_FILE}"
  } > "$SUMMARY_FILE"
  log "summary:"; sed 's/^/    /' "$SUMMARY_FILE" | tee -a "$LOG_FILE"
}

log "HFZ Restore Tickets clone start"
log "work dir  : ${WORK_DIR}"
log "tools     : ${TOOLS_DIR}"
log "flow      : boot ramdisk + mount + restore tickets"
[ "$OLD_MOUNT" = "1" ] && log "mount     : -old enabled; use remote_mount_old.sh"
log "boot      : ${BOOT_SCRIPT} (RUN_BOOT=${RUN_BOOT})"
query_device_meta
log "device   : ECID=${DEVICE_ECID:-N/A} PRODUCT=${DEVICE_PRODUCT:-N/A} MODEL=${DEVICE_MODEL:-N/A}"

INPUT_PATH="$(select_input "$RESTORE_INPUT_ARG")"
log "input    : ${INPUT_PATH}"
UNPACK_DIR="${WORK_DIR}/input"
extract_input "$INPUT_PATH" "$UNPACK_DIR"

TICKETS="$(first_file "$UNPACK_DIR" activation_record.plist || true)"
ICINFO="$(first_file "$UNPACK_DIR" 'IC-Info.sisv' 'IC-Info*.sisv' || true)"
COMM="$(first_file "$UNPACK_DIR" 'com.apple.commcenter.device_specific_nobackup.plist' || true)"
PURPLE_RES="${TOOLS_DIR}/com.apple.purplebuddy.plist"
DISABLED_RES="${TOOLS_DIR}/disabled.plist"

[ -n "$ICINFO" ] && { log "Found: IC-Info.sisv"; add_ok "input icinfo: $ICINFO"; } || { add_miss "IC-Info.sisv not found in zip"; die "Restore cancelled: IC-Info.sisv not found in zip"; }
[ -n "$TICKETS" ] && { log "Found: activation_record.plist"; add_ok "input activation_record: $TICKETS"; } || { add_miss "activation_record.plist not found in zip"; die "Restore cancelled: activation_record.plist not found in zip"; }
[ -n "$COMM" ] && { log "Found: commcenter plist"; add_ok "input comm: $COMM"; } || { add_miss "commcenter plist not found in zip"; die "Restore cancelled: commcenter plist not found in zip"; }
[ -f "$DISABLED_RES" ] || die "missing original resource: $DISABLED_RES"
[ -f "$PURPLE_RES" ] || die "missing original resource: $PURPLE_RES"
log "All required ticket files found in zip."

run_boot_ramdisk
start_iproxy_if_needed
wait_ssh
mount_and_setup_original_restore

log "Restoring tickets via base64..."

remote_exec 10 "test -d /mnt2/mobile/Library/FairPlay && echo 'YES' || echo 'NO'" >/dev/null || true
remote_exec 10 "test -e /dev/disk1s8 && echo 'EXISTS' || echo 'NOT_FOUND'" >/dev/null || true
remote_exec 10 "/System/Library/Filesystems/apfs.fs/apfs.util -p disk1s8" >/dev/null || true
remote_exec 10 "/sbin/umount /mnt8 2>/dev/null" >/dev/null || true
remote_exec 15 "/System/Library/Filesystems/apfs.fs/mount_apfs /dev/disk1s8 /mnt8" >/dev/null || true
remote_exec 10 "test -d /mnt8/mobile/Library/FairPlay && echo 'YES' || echo 'NO'" >/dev/null || true

log "Stage upload restore files to /mnt2/root/.hfz_restore_tmp"
stage_upload_var STAGE_TICKETS activation_record "$TICKETS" && add_ok "stage activation_record: $STAGE_TICKETS" || { add_miss "stage activation_record failed"; die "stage activation_record failed"; }
stage_upload_var STAGE_ICINFO icinfo "$ICINFO" && add_ok "stage icinfo: $STAGE_ICINFO" || { add_miss "stage icinfo failed"; die "stage icinfo failed"; }
stage_upload_var STAGE_COMM comm "$COMM" && add_ok "stage comm: $STAGE_COMM" || { add_miss "stage comm failed"; die "stage comm failed"; }
stage_upload_var STAGE_DISABLED disabled "$DISABLED_RES" && add_ok "stage disabled resource: $STAGE_DISABLED" || { add_miss "stage disabled failed"; die "stage disabled failed"; }
stage_upload_var STAGE_PURPLE purplebuddy "$PURPLE_RES" && add_ok "stage purplebuddy resource: $STAGE_PURPLE" || { add_miss "stage purplebuddy failed"; die "stage purplebuddy failed"; }

remote_exec 40 "/bin/rm -rf /mnt2/containers/Data/System/*/Library/activation_records" >/dev/null || true
remote_exec 40 "/bin/rm -rf /mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" >/dev/null || true
remote_exec 40 "/usr/bin/chflags nouchg /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist 2>/dev/null || /bin/chflags nouchg /mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist 2>/dev/null || true" >/dev/null || true
remote_exec 40 "/usr/bin/chflags nouchg /mnt2/db/com.apple.xpc.launchd/disabled.plist 2>/dev/null || /bin/chflags nouchg /mnt2/db/com.apple.xpc.launchd/disabled.plist 2>/dev/null || true" >/dev/null || true
remote_exec 10 "/sbin/umount /mnt8 2>/dev/null" >/dev/null || true
remote_exec 10 "test -e /dev/disk1s8 && echo 'EXISTS' || echo 'NOT_FOUND'" >/dev/null || true
remote_exec 15 "/System/Library/Filesystems/apfs.fs/mount_apfs /dev/disk1s8 /mnt8" >/dev/null || true
remote_exec 10 "/bin/mkdir -p /mnt2/wireless/activation_records" >/dev/null || true
remote_exec 10 "/bin/mkdir -p /mnt2/wireless/FairPlay/iTunes_Control/iTunes" >/dev/null || true

log "Restore activation_record"
remote_exec 40 "/usr/bin/chflags -R nouchg /mnt2/containers/Data/System/*/Library/activation_records 2>/dev/null || true" || true
remote_exec 40 "/bin/rm -rf /mnt2/containers/Data/System/*/Library/activation_records" || true
remote_exec 20 "/bin/rm -rf /mnt2/wireless/activation_records; /bin/mkdir -p /mnt2/wireless/activation_records" || true
remote_exec 40 "/bin/cp -f '${STAGE_TICKETS}' /mnt2/wireless/activation_records/activation_record.plist || /bin/cat '${STAGE_TICKETS}' > /mnt2/wireless/activation_records/activation_record.plist"
remote_exec 40 "/bin/chmod 777 /mnt2/wireless/activation_records; /bin/chmod 666 /mnt2/wireless/activation_records/activation_record.plist" || true
remote_exec 40 "cd /mnt2/containers/Data/System/*/Library/internal && /bin/mv -f /mnt2/wireless/activation_records ../"
remote_exec 40 "/bin/chmod 777 /mnt2/containers/Data/System/*/Library/activation_records" || true
remote_exec 40 "/usr/sbin/chown -R mobile:nobody /mnt2/containers/Data/System/*/Library/activation_records" || true
remote_exec 40 "/bin/chmod 666 /mnt2/containers/Data/System/*/Library/activation_records/activation_record.plist" || true
remote_exec_retry 3 "chflags-activation_record" "/usr/bin/chflags uchg /mnt2/containers/Data/System/*/Library/activation_records/activation_record.plist 2>/dev/null || /bin/chflags uchg /mnt2/containers/Data/System/*/Library/activation_records/activation_record.plist 2>/dev/null || true" || true
remote_exec_retry 3 "chflags-data_ark" "/usr/bin/chflags uchg /mnt2/containers/Data/System/*/Library/internal/data_ark.plist 2>/dev/null || /bin/chflags uchg /mnt2/containers/Data/System/*/Library/internal/data_ark.plist 2>/dev/null || true" || true
verify_remote_file activation_record "/mnt2/containers/Data/System/*/Library/activation_records/activation_record.plist" && add_ok "restore activation_record final verified" || add_miss "restore activation_record final verify failed"

restore_icinfo_dynamic

log "Restore commcenter plist"
remote_place_file comm "$STAGE_COMM" "/mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist" "600" "_wireless:_wireless" "uchg" && add_ok "restore comm final verified" || add_miss "restore comm failed"

log "Restore disabled.plist"
remote_place_file disabled "$STAGE_DISABLED" "/mnt2/db/com.apple.xpc.launchd/disabled.plist" "644" "" "uchg" && add_ok "restore disabled final verified" || add_miss "restore disabled failed"

log "Restore purplebuddy plist"
PURPLE_DONE=0
if remote_exec 10 "test -e /dev/disk1s8" >/dev/null 2>&1; then
  remote_exec 10 "/bin/mkdir -p /mnt8 2>/dev/null || true; (/sbin/umount /mnt8 2>/dev/null || true); /System/Library/Filesystems/apfs.fs/mount_apfs /dev/disk1s8 /mnt8 2>/dev/null || true" || true
  if remote_exec 10 "test -d /mnt8/Library -o -w /mnt8" >/dev/null 2>&1; then
    remote_exec 10 "/usr/bin/chflags nouchg /mnt8/Library/Preferences/com.apple.purplebuddy.plist 2>/dev/null || /bin/chflags nouchg /mnt8/Library/Preferences/com.apple.purplebuddy.plist 2>/dev/null || true" || true
    remote_place_file purplebuddy_mnt8 "$STAGE_PURPLE" "/mnt8/Library/Preferences/com.apple.purplebuddy.plist" "600" "root:wheel" "uchg" && { add_ok "restore purplebuddy final verified: /mnt8/Library/Preferences/com.apple.purplebuddy.plist"; PURPLE_DONE=1; } || true
  fi
fi
if [ "$PURPLE_DONE" != "1" ]; then
  warn "No writable real /mnt8 User volume; fallback purplebuddy to /mnt2/root source domain"
  remote_place_file purplebuddy_root "$STAGE_PURPLE" "/mnt2/root/Library/Preferences/com.apple.purplebuddy.plist" "600" "root:wheel" "uchg" && add_ok "restore purplebuddy fallback verified: /mnt2/root/Library/Preferences/com.apple.purplebuddy.plist" || add_miss "restore purplebuddy failed"
fi

remote_exec 40 "/bin/rm -rf /mnt2/mobile/Library/Logs/mobileactivationd" || true
remote_exec 10 "/bin/sync" || true

log "Final restore verification overview"
verify_remote_file final_activation_record "/mnt2/containers/Data/System/*/Library/activation_records/activation_record.plist" || true
ICINFO_FINAL="$(resolve_icinfo_dest 2>/dev/null || true)"; [ -n "$ICINFO_FINAL" ] && verify_remote_file final_icinfo "$ICINFO_FINAL" || true
verify_remote_file final_comm "/mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist" || true
verify_remote_file final_disabled "/mnt2/db/com.apple.xpc.launchd/disabled.plist" || true
verify_remote_file final_purplebuddy_mnt8 "/mnt8/Library/Preferences/com.apple.purplebuddy.plist" || true
verify_remote_file final_purplebuddy_root "/mnt2/root/Library/Preferences/com.apple.purplebuddy.plist" || true

log "Ticket restore complete."
write_summary
log "done"
log "summary: ${SUMMARY_FILE}"

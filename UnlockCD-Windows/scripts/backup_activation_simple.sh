#!/bin/bash
#
# backup_activation_simple.sh - Simple backup of 3 critical activation files to ZIP
#
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
info()  { printf "${BLUE}[*]${NC} %s\n" "$*"; }
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -p "${SSH_PORT}")
SSHPASS_BIN=""
find_sshpass() {
  [ -n "$SSHPASS_BIN" ] && return 0
  for candidate in "${SCRIPT_DIR}/sshpass" "$(command -v sshpass 2>/dev/null)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && SSHPASS_BIN="$candidate" && return 0
  done
  return 1
}
ssh_run() {
  if find_sshpass; then sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$1"
  else ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$1"; fi
}
scp_pull() {
  if find_sshpass; then sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}:$1" "$2"
  else scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}:$1" "$2"; fi
}
CRITICAL_FILES=(
  "/mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist"
  "/mnt2/mobile/Library/FairPlay/IC-Info.sisv"
  "/mnt2/containers/Data/System/com.apple.mobileactivationd/Library/ActivationRecords/activation_record.plist"
)
test_connection() {
  out="$(ssh_run "echo XRBOOT_SSH_OK" 2>&1)" || return 1
  echo "$out" | grep -q XRBOOT_SSH_OK
}
file_exists() {
  out="$(ssh_run "[ -f '$1' ] && echo OK" 2>&1)" || return 1
  echo "$out" | grep -q OK
}
do_backup() {
  dest_dir="${1:-.}"
  [ -d "$dest_dir" ] || { error "No dir: $dest_dir"; exit 1; }
  test_connection || { error "SSH fail — iproxy + boot?"; exit 1; }
  ts="$(date +%Y%m%d_%H%M%S)"
  temp_dir="$(mktemp -d)"
  zip_file="${dest_dir}/activation_backup_${ts}.zip"
  found=0
  for remote_path in "${CRITICAL_FILES[@]}"; do
    fn="$(basename "$remote_path")"
    info "Check $remote_path"
    if ! file_exists "$remote_path"; then warn "missing"; continue; fi
    scp_pull "$remote_path" "${temp_dir}/${fn}" && found=$((found+1))
  done
  [ "$found" -gt 0 ] || { error "nothing downloaded"; exit 1; }
  (cd "$temp_dir" && zip -q "$zip_file" ./*)
  rm -rf "$temp_dir"
  log "ZIP: $zip_file ($found files)"
}
do_backup "${1:-.}"

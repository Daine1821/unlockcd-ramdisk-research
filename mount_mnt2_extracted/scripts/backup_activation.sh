#!/bin/bash
#
# backup_activation.sh - Backup/restore activation records, tickets, and network
# files from a device booted into the SSH ramdisk (same architecture as mnt2).
#
# Connects to root@localhost:2222 (password: alpine) through the iproxy USB
# tunnel that mnt2/start.sh establish. Every existence check and every file
# transfer is individually verified — nothing is assumed to have succeeded.
#
# Usage:
#   ./backup_activation.sh backup <destination_dir>
#   ./backup_activation.sh restore <backup_dir>
#   ./backup_activation.sh list <backup_dir>
#   ./backup_activation.sh verify <backup_dir>
#

set -uo pipefail
# NOTE: deliberately NOT using `set -e` here. Every ssh/scp call's exit code
# is checked explicitly and reported. Using -e would risk silently aborting
# mid-loop on the first missing file, which is exactly the kind of "lies
# about found/not-found" behavior we need to avoid.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[-]${NC} %s\n" "$*" >&2; }
info()  { printf "${BLUE}[*]${NC} %s\n" "$*"; }

# --- SSH connection settings (must match mnt2's defaults exactly) ---------
SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"
SSH_CMD_TIMEOUT="${SSH_CMD_TIMEOUT:-15}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o BatchMode=no -p "${SSH_PORT}")

# sshpass may be bundled next to this script (tools/sshpass) for standalone
# operation, or available on PATH.
SSHPASS_BIN=""
find_sshpass() {
  if [ -n "$SSHPASS_BIN" ]; then return 0; fi
  for candidate in "${SCRIPT_DIR}/tools/sshpass" "${SCRIPT_DIR}/sshpass" "$(command -v sshpass 2>/dev/null)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      SSHPASS_BIN="$candidate"
      return 0
    fi
  done
  return 1
}

# Wrap ssh/scp with sshpass if available, otherwise rely on SSH_ASKPASS /
# interactive prompt (will fail non-interactively, which is reported clearly).
ssh_run() {
  # ssh_run <remote-command...>  (single command string executed via ssh -c-style arg)
  local remote_cmd="$1"
  if find_sshpass; then
    "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$remote_cmd"
  else
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$remote_cmd"
  fi
}

scp_pull() {
  # scp_pull <remote_path> <local_path>
  local remote_path="$1" local_path="$2"
  if find_sshpass; then
    "$SSHPASS_BIN" -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" -r \
      "${SSH_USER}@${SSH_HOST}:${remote_path}" "$local_path" >/tmp/xrboot_scp_pull.log 2>&1
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" -r \
      "${SSH_USER}@${SSH_HOST}:${remote_path}" "$local_path" >/tmp/xrboot_scp_pull.log 2>&1
  fi
}

scp_push() {
  # scp_push <local_path> <remote_path>
  local local_path="$1" remote_path="$2"
  if find_sshpass; then
    "$SSHPASS_BIN" -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" -r \
      "$local_path" "${SSH_USER}@${SSH_HOST}:${remote_path}" >/tmp/xrboot_scp_push.log 2>&1
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" -r \
      "$local_path" "${SSH_USER}@${SSH_HOST}:${remote_path}" >/tmp/xrboot_scp_push.log 2>&1
  fi
}

# --- Critical files/dirs to back up (absolute device-side paths) ----------
CRITICAL_FILES=(
  "/private/var/root/Library/Lockdown/activation_records/activation_record.plist"
  "/private/var/root/Library/Lockdown/data_ark.plist"
  "/private/var/root/Library/Lockdown/activation_state.plist"
  "/private/var/root/Library/Lockdown/pair_records"
  "/System/Library/Caches/apticket.der"
  "/usr/standalone/firmware/apticket.der"
  "/private/var/MobileDevice/ProvisioningProfiles"
  "/private/var/preferences/SystemConfiguration/preferences.plist"
  "/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist"
  "/Library/Preferences/SystemConfiguration/com.apple.wifi.plist"
  "/private/var/root/Library/FairPlay"
  "/private/var/wireless/Library/Preferences/com.apple.commcenter.plist"
  "/private/var/mobile/Library/Preferences/com.apple.commcenter.plist"
)

usage() {
  cat <<EOF
Usage: $0 <command> <arguments>

Connects over SSH to a device booted into the ramdisk (root@${SSH_HOST}:${SSH_PORT}),
matching the same connection mnt2 uses. iproxy/USB tunnel must already be
running (start.sh / mnt2 do this automatically).

Commands:
  backup <dest_dir>      Backup activation/network files from the device to dest_dir
  restore <backup_dir>   Restore a previous backup back onto the device
  list <backup_dir>      Show what a backup actually contains
  verify <backup_dir>    Re-check a backup's files still exist and are non-empty

Env overrides:
  SSH_HOST (default: localhost)
  SSH_PORT (default: 2222)
  SSH_USER (default: root)
  SSH_PASS (default: alpine)
EOF
}

# --- Connectivity check -----------------------------------------------------
test_ssh_connection() {
  local out rc
  out="$(ssh_run "echo XRBOOT_SSH_OK" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "XRBOOT_SSH_OK"; then
    return 0
  fi
  warn "SSH connectivity check failed (rc=${rc}): ${out}"
  return 1
}

# --- Accurate existence check: exit code is the single source of truth -----
# Prints exactly one of: FOUND_FILE / FOUND_DIR / NOT_FOUND / CHECK_ERROR
remote_path_status() {
  local remote_path="$1"
  local out rc
  # -f => regular file, -d => directory, else not found. We ask the remote
  # shell to tell us explicitly rather than inferring anything locally.
  out="$(ssh_run "if [ -f '${remote_path}' ]; then echo FOUND_FILE; elif [ -d '${remote_path}' ]; then echo FOUND_DIR; elif [ -e '${remote_path}' ]; then echo FOUND_OTHER; else echo NOT_FOUND; fi" 2>/tmp/xrboot_ssh_err.log)"
  rc=$?
  if [ $rc -ne 0 ]; then
    printf 'CHECK_ERROR'
    return 1
  fi
  case "$out" in
    FOUND_FILE|FOUND_DIR|FOUND_OTHER|NOT_FOUND) printf '%s' "$out"; return 0 ;;
    *) printf 'CHECK_ERROR'; return 1 ;;
  esac
}

# --- Backup -----------------------------------------------------------------
do_backup() {
  local dest_dir="$1"
  if [ -z "$dest_dir" ]; then
    error "Destination directory not specified"; usage; exit 1
  fi

  log "Testing SSH connection to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."
  if ! test_ssh_connection; then
    error "Cannot reach the device over SSH."
    error "Make sure the device finished booting the ramdisk and iproxy is running"
    error "(run start.sh / mnt2 first). Override host/port with SSH_HOST/SSH_PORT."
    exit 1
  fi
  log "SSH connection OK"

  local backup_name="activation_backup_$(date +%Y%m%d_%H%M%S)"
  local backup_path="${dest_dir}/${backup_name}"
  mkdir -p "$backup_path" || { error "Cannot create backup directory: ${backup_path}"; exit 1; }
  : > "${backup_path}/file_list.txt"
  : > "${backup_path}/not_found_list.txt"
  : > "${backup_path}/error_list.txt"

  cat > "${backup_path}/backup_info.txt" <<METADATA
Backup Created: $(date)
SSH Target: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}
METADATA

  local found_count=0 not_found_count=0 error_count=0 transferred_count=0 transfer_failed_count=0

  for remote_path in "${CRITICAL_FILES[@]}"; do
    info "Checking: ${remote_path}"
    local status
    status="$(remote_path_status "$remote_path")"

    case "$status" in
      NOT_FOUND)
        warn "○ Not found on device: ${remote_path}"
        echo "${remote_path}" >> "${backup_path}/not_found_list.txt"
        not_found_count=$((not_found_count+1))
        continue
        ;;
      CHECK_ERROR)
        error "✗ Could not check ${remote_path} (SSH error — see error_list.txt)"
        echo "${remote_path}: $(cat /tmp/xrboot_ssh_err.log 2>/dev/null)" >> "${backup_path}/error_list.txt"
        error_count=$((error_count+1))
        continue
        ;;
      FOUND_FILE|FOUND_DIR|FOUND_OTHER)
        found_count=$((found_count+1))
        ;;
    esac

    # Confirmed to exist on the device — now actually transfer it, and verify
    # the transfer, rather than assuming scp succeeded because it exited 0
    # (scp can exit 0 while writing a 0-byte file on some failure paths, so
    # we explicitly re-check the local copy afterward too).
    local rel_path="${remote_path#/}"
    local dest_file="${backup_path}/${rel_path}"
    mkdir -p "$(dirname "$dest_file")"

    if scp_pull "$remote_path" "$dest_file"; then
      if [ -e "$dest_file" ]; then
        log "✓ Backed up: ${remote_path}"
        echo "${remote_path}" >> "${backup_path}/file_list.txt"
        transferred_count=$((transferred_count+1))
      else
        error "✗ scp reported success but local file is missing: ${remote_path}"
        echo "${remote_path}: scp exited 0 but destination missing" >> "${backup_path}/error_list.txt"
        transfer_failed_count=$((transfer_failed_count+1))
      fi
    else
      error "✗ Transfer failed: ${remote_path} ($(cat /tmp/xrboot_scp_pull.log 2>/dev/null | tail -1))"
      echo "${remote_path}: $(cat /tmp/xrboot_scp_pull.log 2>/dev/null | tail -1)" >> "${backup_path}/error_list.txt"
      transfer_failed_count=$((transfer_failed_count+1))
    fi
  done

  rm -f /tmp/xrboot_ssh_err.log /tmp/xrboot_scp_pull.log

  log ""
  log "=========================================="
  log "Backup Summary (${backup_path}):"
  log "  Present on device : ${found_count}"
  log "  Not found on device: ${not_found_count}"
  log "  Successfully saved : ${transferred_count}"
  log "  Transfer failures   : ${transfer_failed_count}"
  log "  Check errors        : ${error_count}"
  log "=========================================="

  if [ "$transferred_count" -eq 0 ]; then
    error "Nothing was backed up. Either the device has none of the expected files,"
    error "or SSH access to the device filesystem is restricted. See ${backup_path}/error_list.txt"
  fi

  cat > "${backup_path}/restore.sh" <<'RESTORE_SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$(dirname "$SCRIPT_DIR")")"
./backup_activation.sh restore "$SCRIPT_DIR"
RESTORE_SCRIPT
  chmod +x "${backup_path}/restore.sh"
  log "Backup complete: ${backup_path}"
}

# --- Restore -----------------------------------------------------------------
do_restore() {
  local src_dir="$1"
  if [ -z "$src_dir" ]; then
    error "Backup directory not specified"; usage; exit 1
  fi
  if [ ! -d "$src_dir" ]; then
    error "Backup directory does not exist: ${src_dir}"; exit 1
  fi
  if [ ! -f "${src_dir}/file_list.txt" ]; then
    error "Invalid backup directory (missing file_list.txt): ${src_dir}"; exit 1
  fi

  log "Testing SSH connection to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."
  if ! test_ssh_connection; then
    error "Cannot reach the device over SSH. Boot the ramdisk and start iproxy first."
    exit 1
  fi
  log "SSH connection OK"

  if [ -f "${src_dir}/backup_info.txt" ]; then
    info "Backup info:"
    while IFS= read -r line; do info "  ${line}"; done < "${src_dir}/backup_info.txt"
  fi

  warn "This will overwrite files on the connected device. Ctrl+C within 3s to cancel..."
  sleep 3

  local restored_count=0 failed_count=0 missing_local_count=0

  while IFS= read -r remote_path; do
    [ -n "$remote_path" ] || continue
    local rel_path="${remote_path#/}"
    local src_file="${src_dir}/${rel_path}"

    if [ ! -e "$src_file" ]; then
      warn "○ Backup copy missing locally, skipping: ${src_file}"
      missing_local_count=$((missing_local_count+1))
      continue
    fi

    info "Restoring: ${remote_path}"
    local parent_dir
    parent_dir="$(dirname "$remote_path")"
    ssh_run "mkdir -p '${parent_dir}'" >/dev/null 2>&1

    if scp_push "$src_file" "$remote_path"; then
      # Verify the remote side actually has it now.
      local status
      status="$(remote_path_status "$remote_path")"
      if [ "$status" = "FOUND_FILE" ] || [ "$status" = "FOUND_DIR" ] || [ "$status" = "FOUND_OTHER" ]; then
        log "✓ Restored: ${remote_path}"
        restored_count=$((restored_count+1))
      else
        error "✗ scp exited 0 but device does not report the file present: ${remote_path}"
        failed_count=$((failed_count+1))
      fi
    else
      error "✗ Failed to push: ${remote_path} ($(cat /tmp/xrboot_scp_push.log 2>/dev/null | tail -1))"
      failed_count=$((failed_count+1))
    fi
  done < "${src_dir}/file_list.txt"

  rm -f /tmp/xrboot_scp_push.log /tmp/xrboot_ssh_err.log

  log ""
  log "=========================================="
  log "Restore Summary:"
  log "  Restored             : ${restored_count}"
  log "  Failed                : ${failed_count}"
  log "  Missing local copy    : ${missing_local_count}"
  log "=========================================="
}

# --- List --------------------------------------------------------------------
do_list() {
  local backup_dir="$1"
  if [ -z "$backup_dir" ]; then error "Backup directory not specified"; usage; exit 1; fi
  if [ ! -d "$backup_dir" ]; then error "Backup directory does not exist: ${backup_dir}"; exit 1; fi

  log "Backup contents: ${backup_dir}"
  if [ -f "${backup_dir}/backup_info.txt" ]; then
    info "Info:"; cat "${backup_dir}/backup_info.txt"
  fi

  if [ -f "${backup_dir}/file_list.txt" ] && [ -s "${backup_dir}/file_list.txt" ]; then
    log "Successfully backed up files:"
    local count=0
    while IFS= read -r remote_path; do
      [ -n "$remote_path" ] || continue
      local rel_path="${remote_path#/}"
      local local_copy="${backup_dir}/${rel_path}"
      if [ -e "$local_copy" ]; then
        local size
        size="$(du -h "$local_copy" 2>/dev/null | cut -f1)"
        info "  [${size}] ${remote_path}"
      else
        warn "  [MISSING LOCALLY] ${remote_path}  <- listed but not actually present, backup is corrupt"
      fi
      count=$((count+1))
    done < "${backup_dir}/file_list.txt"
    log "Total: ${count}"
  else
    warn "No files were successfully backed up in this backup."
  fi

  if [ -f "${backup_dir}/not_found_list.txt" ] && [ -s "${backup_dir}/not_found_list.txt" ]; then
    log ""
    log "Not present on the device at backup time:"
    while IFS= read -r p; do [ -n "$p" ] && info "  ${p}"; done < "${backup_dir}/not_found_list.txt"
  fi

  if [ -f "${backup_dir}/error_list.txt" ] && [ -s "${backup_dir}/error_list.txt" ]; then
    log ""
    warn "Errors encountered during backup:"
    while IFS= read -r p; do [ -n "$p" ] && warn "  ${p}"; done < "${backup_dir}/error_list.txt"
  fi
}

# --- Verify --------------------------------------------------------------------
do_verify() {
  local backup_dir="$1"
  if [ -z "$backup_dir" ]; then error "Backup directory not specified"; usage; exit 1; fi
  if [ ! -d "$backup_dir" ]; then error "Backup directory does not exist: ${backup_dir}"; exit 1; fi

  log "Verifying local backup integrity: ${backup_dir}"
  local total=0 valid=0 invalid=0 empty=0

  if [ -f "${backup_dir}/file_list.txt" ]; then
    while IFS= read -r remote_path; do
      [ -n "$remote_path" ] || continue
      total=$((total+1))
      local rel_path="${remote_path#/}"
      local local_copy="${backup_dir}/${rel_path}"

      if [ ! -e "$local_copy" ]; then
        error "✗ Missing: ${remote_path}"
        invalid=$((invalid+1))
      elif [ -f "$local_copy" ] && [ ! -s "$local_copy" ]; then
        warn "⚠ Present but empty (0 bytes): ${remote_path}"
        empty=$((empty+1))
        valid=$((valid+1))
      else
        log "✓ Valid: ${remote_path}"
        valid=$((valid+1))
      fi
    done < "${backup_dir}/file_list.txt"
  fi

  log ""
  log "=========================================="
  log "Verification Summary:"
  log "  Total     : ${total}"
  log "  Valid     : ${valid} (of which ${empty} are 0 bytes)"
  log "  Missing   : ${invalid}"
  log "=========================================="

  [ "$invalid" -eq 0 ]
}

main() {
  if [ $# -lt 1 ]; then usage; exit 1; fi
  local command="$1"; shift

  case "$command" in
    backup)
      [ $# -ge 1 ] || { error "backup requires <destination_dir>"; usage; exit 1; }
      do_backup "$@"
      ;;
    restore)
      [ $# -ge 1 ] || { error "restore requires <backup_dir>"; usage; exit 1; }
      do_restore "$@"
      ;;
    list)    do_list "$@" ;;
    verify)  do_verify "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown command: $command"; usage; exit 1 ;;
  esac
}

main "$@"

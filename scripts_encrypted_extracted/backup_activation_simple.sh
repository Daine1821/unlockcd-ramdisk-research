#!/bin/bash
#
# backup_activation_simple.sh - Simple backup of 3 critical activation files to ZIP
#
# Creates a ZIP archive containing only:
#   1. IC-Info.sisv
#   2. com.apple.commcenter.device_specific_nobackup.plist  
#   3. activation_record.plist
#
# Usage:
#   ./backup_activation_simple.sh [destination_dir]
#

set -uo pipefail

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

# SSH connection settings (same as mnt2 defaults)
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -o BatchMode=no -p "${SSH_PORT}")

# Find sshpass
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

ssh_run() {
  local remote_cmd="$1"
  if find_sshpass; then
    "$SSHPASS_BIN" -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$remote_cmd"
  else
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$remote_cmd"
  fi
}

scp_pull() {
  local remote_path="$1" local_path="$2"
  if find_sshpass; then
    "$SSHPASS_BIN" -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" \
      "${SSH_USER}@${SSH_HOST}:${remote_path}" "$local_path" 2>&1
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}" -P "${SSH_PORT}" \
      "${SSH_USER}@${SSH_HOST}:${remote_path}" "$local_path" 2>&1
  fi
}

# The 3 critical files we need from /mnt2
CRITICAL_FILES=(
  "/mnt2/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist"
  "/mnt2/mobile/Library/FairPlay/IC-Info.sisv"
  "/mnt2/containers/Data/System/com.apple.mobileactivationd/Library/ActivationRecords/activation_record.plist"
)

# Test SSH connection
test_connection() {
  log "Testing SSH connection to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."
  local out rc
  out="$(ssh_run "echo XRBOOT_SSH_OK" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "XRBOOT_SSH_OK"; then
    log "✓ SSH connection OK"
    return 0
  fi
  error "SSH connection failed (rc=${rc}): ${out}"
  return 1
}

# Check if file exists on device
file_exists() {
  local remote_path="$1"
  local out rc
  out="$(ssh_run "[ -f '${remote_path}' ] && echo OK" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "OK"; then
    return 0
  fi
  return 1
}

# Main backup function
do_backup() {
  local dest_dir="${1:-.}"
  
  if [ ! -d "$dest_dir" ]; then
    error "Destination directory does not exist: $dest_dir"
    exit 1
  fi
  
  log "Starting simple activation backup..."
  
  # Test connection first
  if ! test_connection; then
    error "Cannot connect to device. Make sure:"
    error "  1. Device is booted into SSH ramdisk"
    error "  2. iproxy is running on port ${SSH_PORT}"
    error "  3. /mnt2 is mounted on device"
    exit 1
  fi
  
  # Create temporary directory for downloaded files
  local timestamp="$(date +%Y%m%d_%H%M%S)"
  local backup_name="activation_backup_${timestamp}"
  local temp_dir="/tmp/${backup_name}"
  local zip_file="${dest_dir}/${backup_name}.zip"
  
  rm -rf "$temp_dir"
  mkdir -p "$temp_dir" || { error "Failed to create temp directory"; exit 1; }
  
  log "Temporary directory: $temp_dir"
  log "Output ZIP: $zip_file"
  echo
  
  local found_count=0
  local missing_count=0
  local failed_count=0
  
  # Check and download each file
  for remote_path in "${CRITICAL_FILES[@]}"; do
    local filename="$(basename "$remote_path")"
    local local_path="${temp_dir}/${filename}"
    
    info "Checking: $remote_path"
    
    if ! file_exists "$remote_path"; then
      warn "  ✗ File not found on device"
      missing_count=$((missing_count + 1))
      continue
    fi
    
    info "  ✓ File exists, downloading..."
    
    if scp_pull "$remote_path" "$local_path"; then
      if [ -f "$local_path" ] && [ -s "$local_path" ]; then
        local size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path" 2>/dev/null)
        log "  ✓ Downloaded: $filename (${size} bytes)"
        found_count=$((found_count + 1))
      else
        error "  ✗ Download succeeded but file is empty or missing"
        failed_count=$((failed_count + 1))
      fi
    else
      error "  ✗ Download failed"
      failed_count=$((failed_count + 1))
    fi
  done
  
  echo
  log "Download summary:"
  log "  ✓ Successfully downloaded: $found_count"
  if [ $missing_count -gt 0 ]; then
    warn "  ⚠ Not found on device: $missing_count"
  fi
  if [ $failed_count -gt 0 ]; then
    error "  ✗ Failed to download: $failed_count"
  fi
  
  if [ $found_count -eq 0 ]; then
    error "No files were downloaded. Backup failed."
    rm -rf "$temp_dir"
    exit 1
  fi
  
  echo
  log "Creating ZIP archive..."
  
  # Create ZIP file
  cd "$temp_dir" || exit 1
  if zip -q "$zip_file" * 2>/dev/null; then
    log "✓ ZIP archive created successfully"
  else
    error "Failed to create ZIP archive"
    cd - >/dev/null
    rm -rf "$temp_dir"
    exit 1
  fi
  cd - >/dev/null
  
  # Verify ZIP
  local zip_size=$(stat -f%z "$zip_file" 2>/dev/null || stat -c%s "$zip_file" 2>/dev/null)
  log "✓ Archive size: ${zip_size} bytes"
  
  # Clean up temp directory
  rm -rf "$temp_dir"
  
  echo
  log "═══════════════════════════════════════════════════════════"
  log "✅ BACKUP COMPLETE"
  log "═══════════════════════════════════════════════════════════"
  log "Backup file: $zip_file"
  log "Files in archive: $found_count"
  echo
  
  # List ZIP contents
  info "Archive contents:"
  unzip -l "$zip_file" 2>/dev/null | tail -n +4 | head -n -2
  
  echo
  log "To extract this backup:"
  log "  unzip $zip_file"
  
  return 0
}

# Parse command line
if [ $# -eq 0 ]; then
  do_backup "."
elif [ $# -eq 1 ]; then
  do_backup "$1"
else
  cat <<EOF
Usage: $0 [destination_directory]

Simple backup tool that creates a ZIP archive with 3 critical activation files:
  1. IC-Info.sisv
  2. com.apple.commcenter.device_specific_nobackup.plist
  3. activation_record.plist

The tool connects to root@${SSH_HOST}:${SSH_PORT} (same as mnt2/start.sh).

Example:
  $0                    # Save to current directory
  $0 ~/Desktop          # Save to Desktop
  $0 ./backups          # Save to backups folder

Environment variables:
  SSH_HOST (default: 127.0.0.1)
  SSH_PORT (default: 2222)
  SSH_USER (default: root)
  SSH_PASS (default: alpine)
EOF
  exit 1
fi

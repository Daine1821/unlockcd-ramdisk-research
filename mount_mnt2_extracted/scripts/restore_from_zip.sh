#!/bin/bash
# Host-side: unzip tickets + scp + run remote HFZ restore (UnlockCD restore.log flow)
set -uo pipefail
ZIP="${1:?usage: restore_from_zip.sh tickets.zip}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_PASS="${SSH_PASS:-alpine}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ucrestore)"
trap 'rm -rf "$WORK"' EXIT

SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH_OPTS=("${SCP_OPTS[@]}" -p "$SSH_PORT")
scp_cmd() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SSH_PASS" scp "${SCP_OPTS[@]}" -P "$SSH_PORT" "$@"
  else
    scp "${SCP_OPTS[@]}" -P "$SSH_PORT" "$@"
  fi
}
ssh_cmd() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$@"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$@"
  fi
}

unzip -qo "$ZIP" -d "$WORK" || { echo "unzip failed"; exit 1; }
echo "[+] Upload + restore on device..."
for f in "$WORK"/*; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  scp_cmd "$f" "$SSH_USER@$SSH_HOST:/var/root/incoming_$base" || exit 1
done
type "$SCRIPT_DIR/restore_tickets_remote.sh" | ssh_cmd sh -s
echo "[+] Done"

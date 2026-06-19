#!/bin/bash
# STS refresh — re-mint AWS credentials into ~/.aws/credentials.
# A static STS profile expires every 1h; the 8789 hook can only re-read the
# file, so something must keep the file fresh. Run by launchd
# (<ORG>.sts-refresh) on a 45-min StartInterval (one-shot, KeepAlive=false).
set -euo pipefail

LOG="$HOME/.local/combo-services/logs/sts-refresh.log"
mkdir -p "$(dirname "$LOG")"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] sts-refresh start" >> "$LOG"
# Replace with your own ADFS/SSO/credential_process refresh command that
# rewrites ~/.aws/credentials (incl. the aws_session_expiration line).
if <STS_REFRESH_CMD> >> "$LOG" 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] sts-refresh OK" >> "$LOG"
else
  rc=$?
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] sts-refresh FAILED rc=$rc" >> "$LOG"
  exit "$rc"
fi

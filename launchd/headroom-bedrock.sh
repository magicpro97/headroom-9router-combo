#!/bin/bash
# headroom BEDROCK (port 8789) — STS auto-refresh bridge behind 9router.
# 9router's Bedrock provider forwards hr/* / sonnet / haiku here; this proxy
# talks to AWS Bedrock with auto-refreshing STS via the --bedrock-client-hook.
# Requires the PR #1104 / fork build of headroom.
# Run by launchd (<ORG>.headroom-bedrock), KeepAlive=true.
set -euo pipefail

BEDROCK_BIN="<HEADROOM_BEDROCK_BIN>"
LOG="$HOME/.local/combo-services/logs/headroom-bedrock.log"
mkdir -p "$(dirname "$LOG")"

# Make the bedrock_refresh.py hook importable.
export PYTHONPATH="<BEDROCK_REFRESH_PYPATH>:${PYTHONPATH:-}"
export AWS_PROFILE="<AWS_PROFILE>"
export AWS_REGION="<AWS_REGION>"

# Ensure at least one valid STS session before serving (seed the hook).
# Replace with your own check/refresh commands.
<STS_REFRESH_CMD> >> "$LOG" 2>&1 || true

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting headroom bedrock :8789" >> "$LOG"
exec "$BEDROCK_BIN" proxy \
  --port 8789 \
  --backend bedrock \
  --region "<AWS_REGION>" \
  --bedrock-client-hook bedrock_refresh:make_client \
  >> "$LOG" 2>&1

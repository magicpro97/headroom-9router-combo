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

# Make the bedrock_refresh.py hook importable. Point this at the dir that
# holds bedrock_refresh.py — this repo ships it right here in launchd/, so
# <BEDROCK_REFRESH_PYPATH> is typically <COMBO_DIR>/launchd.
export PYTHONPATH="<BEDROCK_REFRESH_PYPATH>:${PYTHONPATH:-}"
export AWS_PROFILE="<AWS_PROFILE>"
export AWS_REGION="<AWS_REGION>"
# Lets bedrock_refresh.py self-heal a missed refresh tick: it runs this only
# when ~/.aws/credentials is already expired. Safe to leave unset.
export STS_REFRESH_CMD="<STS_REFRESH_CMD>"

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

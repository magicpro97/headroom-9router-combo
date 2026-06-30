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
# Optional self-heal: bedrock_refresh.py runs this ONLY when ~/.aws/credentials
# is already expired. Set it to your STS re-mint command to enable; leave it
# empty ("") to disable self-heal.
export STS_REFRESH_CMD="<STS_REFRESH_CMD>"

# Best-effort pre-warm of STS before serving. Not a hard gate: the hook also
# self-seeds in make_client() via _refresh_credentials(), which uses check=True
# and fails fast if creds genuinely can't be minted. So a failure here is
# logged but does not block startup (KeepAlive would otherwise thrash). Guarded
# so an un-substituted placeholder doesn't break the shell.
if [ -n "$STS_REFRESH_CMD" ] && [ "$STS_REFRESH_CMD" != "<STS_REFRESH_CMD>" ]; then
  eval "$STS_REFRESH_CMD" >> "$LOG" 2>&1 || \
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN seed STS_REFRESH_CMD failed; hook will self-seed" >> "$LOG"
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting headroom bedrock :8789" >> "$LOG"
exec "$BEDROCK_BIN" proxy \
  --port 8789 \
  --backend bedrock \
  --region "<AWS_REGION>" \
  --bedrock-client-hook bedrock_refresh:make_client \
  >> "$LOG" 2>&1

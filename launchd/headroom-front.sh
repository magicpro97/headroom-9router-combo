#!/bin/bash
# headroom FRONT (port 8787) — compression gateway in front of 9router.
# Tools (Claude Code, Codex, OpenCode) point at http://127.0.0.1:8787.
# Run by launchd (<ORG>.headroom-front), KeepAlive=true.
set -euo pipefail

FRONT_BIN="<HEADROOM_FRONT_BIN>"
ROUTER="http://127.0.0.1:20128/v1"
LOG="$HOME/.local/combo-services/logs/headroom-front.log"
mkdir -p "$(dirname "$LOG")"

export OPENAI_TARGET_API_URL="$ROUTER"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] starting headroom front :8787 -> $ROUTER (compression ON)" >> "$LOG"
# --backend anthropic (NOT litellm-openai, which forces real api.openai.com).
# --mode token + --code-aware = real compression (needs headroom-ai[code]).
# Drop --code-aware if tree-sitter isn't installed; drop to --no-optimize for passthrough.
exec "$FRONT_BIN" proxy \
  --host 127.0.0.1 \
  --port 8787 \
  --workers 1 \
  --backend anthropic \
  --mode token \
  --code-aware \
  --openai-api-url "$ROUTER" \
  --anthropic-api-url "$ROUTER" \
  >> "$LOG" 2>&1

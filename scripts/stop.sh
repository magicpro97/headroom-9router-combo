#!/usr/bin/env bash
# Stop the headroom combo. Works for both host process and docker.
# 9router is left running on the host.
set -euo pipefail
cd "$(dirname "$0")/.."

# Stop host process if running
if pgrep -f "headroom proxy" >/dev/null 2>&1; then
  pkill -f "headroom proxy"
  echo "headroom host process stopped."
fi

# Stop docker container (best-effort)
if command -v docker >/dev/null 2>&1; then
  COMPOSE_PROFILES=host docker compose down 2>/dev/null || true
  docker compose down 2>/dev/null || true
  echo "headroom docker container removed (if any)."
fi

echo "9router still running on the host."

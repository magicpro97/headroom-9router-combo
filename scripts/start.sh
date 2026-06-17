#!/usr/bin/env bash
# Start the headroom combo.
# On macOS, runs headroom as a host process (best path).
# On Linux, supports both bridge (with API key) and host network profiles.

set -euo pipefail
cd "$(dirname "$0")/.."

# Detect OS for default strategy
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  STRATEGY="host"
else
  STRATEGY="${STRATEGY:-host}"  # default on Linux too
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from .env.example. Edit if 9router is not on localhost:20128."
fi

# Source env for the host-strategy case
set -a
. ./.env
set +a

# Quick reachability check on 9router
# On macOS, the headroom host process must use 127.0.0.1 (host.docker.internal
# only resolves inside docker). For docker compose, .env's host.docker.internal
# is correct. Override here for the host-process path.
OS="$(uname -s)"
if [ "$OS" = "Darwin" ] && [ "$STRATEGY" = "host" ]; then
  ROUTER="http://127.0.0.1:20128"
else
  ROUTER="${NINE_ROUTER_BASE:-http://127.0.0.1:20128}"
fi
if ! curl -sf --max-time 5 "${ROUTER}/api/health" > /dev/null 2>&1; then
  echo "9router is not reachable at $ROUTER"
  echo "Start 9router first (host process), then retry."
  exit 1
fi
echo "9router reachable ✓"

start_host_process() {
  if ! command -v headroom >/dev/null 2>&1; then
    echo "headroom not installed. Installing via pip..."
    pip3 install --user 'headroom-ai[proxy]'
    # PATH may not be set in subshells
    export PATH="$HOME/Library/Python/3.12/bin:$PATH"
  fi
  if [ -f /Users/linhn/Library/Python/3.12/bin/headroom ]; then
    export PATH="/Users/linhn/Library/Python/3.12/bin:$PATH"
  fi

  # Avoid double-start
  if pgrep -f "headroom proxy" >/dev/null 2>&1; then
    echo "headroom already running. Reload via 'pkill -f \"headroom proxy\"' then re-run."
    return 0
  fi

  # COMPRESSION_MODE: passthrough (default) vs learn (compression on)
  # - passthrough: --no-optimize (no extra LLM calls, free, no token savings)
  # - learn: --backend litellm-openai (litellm + 9router, opportunistic compression)
  #   Tokens saved on tool outputs, Read results, repeated content. Adds latency
  #   for compression calls (each call is 1 extra 9router request).
  local headroom_args=(
    --host 0.0.0.0 --port 8787 --workers 1
    --openai-api-url "${ROUTER}/v1"
    --anthropic-api-url "${ROUTER}/v1"
    --cloudcode-api-url "${ROUTER}/v1"
  )
  if [ "${COMPRESSION_MODE:-passthrough}" = "learn" ]; then
    headroom_args+=(--backend litellm-openai)
    # 9router doesn't validate the key; any non-empty string works
    export OPENAI_API_KEY="${OPENAI_API_KEY:-sk-n...figurable}"
    export OPENAI_API_BASE="${ROUTER}/v1"
  else
    headroom_args+=(--no-optimize --no-cache)
  fi

  headroom proxy "${headroom_args[@]}" \
    > /tmp/headroom-combo.log 2>&1 &
  echo "Started headroom (pid $!), log: /tmp/headroom-combo.log"
}

start_docker() {
  local profile="$1"
  COMPOSE_PROFILES="$profile" docker compose up -d
}

case "$STRATEGY" in
  host)
    if [ "$OS" = "Darwin" ]; then
      start_host_process
    else
      COMPOSE_PROFILES=host docker compose up -d
    fi
    ;;
  bridge)
    docker compose up -d
    ;;
  *)
    echo "Unknown strategy: $STRATEGY"; exit 1
    ;;
esac

echo
echo "Waiting for headroom to become healthy..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8787/livez 2>/dev/null | grep -q healthy; then
    echo "headroom healthy ✓"
    echo
    echo "Combo ready: http://localhost:8787"
    echo "  OpenAI Chat:  http://localhost:8787/v1/chat/completions"
    echo "  Anthropic:    http://localhost:8787/v1/messages"
    echo "  Codex/Copilot: http://localhost:8787/v1/responses"
    exit 0
  fi
  sleep 1
done

echo "headroom did not become healthy in 30s."
if [ "$STRATEGY" = "host" ] && [ "$OS" = "Darwin" ]; then
  echo "Check /tmp/headroom-combo.log"
else
  echo "Check 'docker compose logs'."
fi
exit 1

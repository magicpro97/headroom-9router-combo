#!/usr/bin/env bash
# Smoke-test all 4 tools against the combo.
# Returns 0 if all 4 respond 2xx within timeout, 1 otherwise.

set -uo pipefail

BASE=${HEADROOM_BASE:-http://localhost:8787}
COMBO_MODEL=${COMBO_MODEL:-cheap}
PROMPT="Reply with the single word: hi"
PASS=0
FAIL=0

check_status () {
  local name="$1"
  local cmd="$2"
  local timeout_s="$3"

  echo -n "  $name: "
  if timeout "$timeout_s" bash -c "$cmd" > /tmp/combo-test.out 2>&1; then
    local status
    status=$(head -1 /tmp/combo-test.out 2>/dev/null || echo "?")
    if [[ "$status" =~ ^2 ]]; then
      echo "OK ($status)"
      PASS=$((PASS+1))
    else
      echo "FAIL (status=$status)"
      FAIL=$((FAIL+1))
      cat /tmp/combo-test.out
    fi
  else
    echo "FAIL (timeout or error)"
    FAIL=$((FAIL+1))
    cat /tmp/combo-test.out | head -5
  fi
}

echo "headroom combo smoke test @ $BASE"
echo

# 1. Raw OpenAI Chat Completions
echo "[1/4] OpenAI Chat Completions (raw curl)"
JSON='{"model":"'"$COMBO_MODEL"'","messages":[{"role":"user","content":"'"$PROMPT"'"}],"stream":false,"max_tokens":50}'
check_status "openai-curl" "curl -s -o /tmp/combo-test.out -w '%{http_code}' -X POST $BASE/v1/chat/completions -H 'Content-Type: application/json' -d '$JSON'" 30

# 2. claude-code (Anthropic)
echo "[2/4] claude-code (anthropic)"
if command -v claude >/dev/null 2>&1; then
  check_status "claude-code" "ANTHROPIC_BASE_URL=$BASE ANTHROPIC_API_KEY=*** anthropic_model=$COMBO_MODEL claude -p '$PROMPT' --model $COMBO_MODEL" 60
else
  echo "  claude-code: SKIP (not installed)"
fi

# 3. opencode
echo "[3/4] opencode"
if command -v opencode >/dev/null 2>&1; then
  check_status "opencode" "opencode run '$PROMPT' -m '9router/$COMBO_MODEL'" 60
else
  echo "  opencode: SKIP (not installed)"
fi

# 4. codex
echo "[4/4] codex"
if command -v codex >/dev/null 2>&1; then
  check_status "codex" "OPENAI_BASE_URL=$BASE/v1 OPENAI_API_KEY=*** codex exec --model $COMBO_MODEL --skip-git-repo-check '$PROMPT'" 60
else
  echo "  codex: SKIP (not installed)"
fi

echo
echo "─── Result: $PASS passed, $FAIL failed ───"
[ "$FAIL" -eq 0 ]

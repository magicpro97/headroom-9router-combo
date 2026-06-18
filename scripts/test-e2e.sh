#!/usr/bin/env bash
# Smoke-test the 3 tools that can be pointed at the combo:
# codex, claude-code, opencode. Copilot is excluded — it has no
# custom-base-URL support in 1.0.63+ and goes through 9router's
# MITM daemon instead, which this combo cannot intercept.
#
# Returns 0 if all 3 respond with "hi" within timeout, 1 otherwise.
#
# Note: tools don't return an HTTP status code to stdout — they
# return the model's reply. So we check for a positive reply
# (the model said "hi") rather than a 2xx status line.

set -uo pipefail

BASE=${HEADROOM_BASE:-http://localhost:8787}
COMBO_MODEL=${COMBO_MODEL:-cheap}
PROMPT="Reply with the single word: hi"
PASS=0
FAIL=0

check_reply () {
  local name="$1"
  local cmd="$2"
  local timeout_s="$3"
  local expect="$4"   # substring expected in output

  echo -n "  $name: "
  if timeout "$timeout_s" bash -c "$cmd" > /tmp/combo-test.out 2>&1; then
    if grep -qF "$expect" /tmp/combo-test.out; then
      echo "OK (got: $expect)"
      PASS=$((PASS+1))
    else
      echo "FAIL (no '$expect' in output)"
      FAIL=$((FAIL+1))
      head -5 /tmp/combo-test.out
    fi
  else
    echo "FAIL (timeout or error)"
    FAIL=$((FAIL+1))
    head -5 /tmp/combo-test.out
  fi
}

echo "headroom combo smoke test @ $BASE, model=$COMBO_MODEL"
echo "  (copilot excluded — see docs/TOOLS.md for why)"
echo

# 1. Raw OpenAI Chat Completions (curl returns HTTP status code on stderr)
echo "[1/4] OpenAI Chat Completions (raw curl)"
JSON='{"model":"'"$COMBO_MODEL"'","messages":[{"role":"user","content":"'"$PROMPT"'"}],"stream":false,"max_tokens":50}'
HTTP_CODE=$(curl -s -o /tmp/combo-test.out -w '%{http_code}' -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "$JSON" --max-time 30)
echo -n "  openai-curl: "
if [[ "$HTTP_CODE" =~ ^2 ]]; then
  echo "OK ($HTTP_CODE)"
  PASS=$((PASS+1))
else
  echo "FAIL (status=$HTTP_CODE)"
  cat /tmp/combo-test.out
  FAIL=$((FAIL+1))
fi

# 2. claude-code (Anthropic protocol)
echo "[2/4] claude-code (anthropic)"
if command -v claude >/dev/null 2>&1; then
  check_reply "claude-code" \
    "ANTHROPIC_BASE_URL=$BASE ANTHROPIC_API_KEY=*** ANTHROPIC_MODEL=$COMBO_MODEL claude -p '$PROMPT' --model $COMBO_MODEL" \
    60 "hi"
else
  echo "  claude-code: SKIP (not installed)"
fi

# 3. opencode
echo "[3/4] opencode"
if command -v opencode >/dev/null 2>&1; then
  check_reply "opencode" \
    "opencode run '$PROMPT' -m 'headroom/$COMBO_MODEL'" \
    60 "hi"
else
  echo "  opencode: SKIP (not installed)"
fi

# 4. codex
echo "[4/4] codex"
if command -v codex >/dev/null 2>&1; then
  check_reply "codex" \
    "OPENAI_BASE_URL=$BASE/v1 OPENAI_API_KEY=*** codex exec --model $COMBO_MODEL --skip-git-repo-check '$PROMPT'" \
    60 "hi"
else
  echo "  codex: SKIP (not installed)"
fi

echo
echo "─── Result: $PASS passed, $FAIL failed ───"
[ "$FAIL" -eq 0 ]

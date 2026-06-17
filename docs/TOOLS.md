# Per-tool setup

After `docker compose up -d` and verifying `:8787` is live, point each tool
at the combo. Every tool only sees `http://localhost:8787` — 9router stays
invisible.

---

## codex (OpenAI CLI)

```bash
export OPENAI_BASE_URL=http://localhost:8787/v1
export OPENAI_API_KEY=*** model cheap
```

Or in `~/.codex/config.toml`:

```toml
[model]
name = "cheap"

[provider]
base_url = "http://localhost:8787/v1"
api_key = "***```

Test:
```bash
codex exec --model cheap "Reply with just: hi"
```

---

## claude-code (Anthropic CLI)

```bash
export ANTHROPIC_BASE_URL=http://localhost:8787
export ANTHROPIC_API_KEY=*** export ANTHROPIC_MODEL=cheap
```

Test:
```bash
claude -p "Reply with just: hi" --model cheap
```

---

## opencode

Edit `~/.config/opencode/opencode.json`, add a `headroom` provider:

```json
{
  "provider": {
    "headroom": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://127.0.0.1:8787/v1",
        "apiKey": "***"
      },
      "models": {
        "cheap": {
          "name": "cheap (combo)",
          "modalities": { "input": ["text"], "output": ["text"] }
        }
      }
    }
  },
  "model": "headroom/cheap"
}
```

Test:
```bash
opencode run "Reply with just: hi" -m "headroom/cheap"
```

---

## copilot (GitHub Copilot CLI ≥ 1.0.63)

The BYOK mode in 1.0.63+ does strict response validation. Setting `claude-*`
model names against an OpenAI Chat endpoint triggers a 5x retry storm because
Copilot expects Anthropic-protocol responses.

The combo dodges this two ways:

1. **`COPILOT_PROVIDER_TYPE=openai`** tells Copilot to use OpenAI Chat
   Completions — no Anthropic-protocol validation runs.
2. **The combo name `cheap` is not a `claude-*` string** — 9router routes it
   to upstream regardless of the `claude-*` shape check.

```bash
export COPILOT_PROVIDER_TYPE=openai
export COPILOT_PROVIDER_BASE_URL=http://localhost:8787/v1
export COPILOT_PROVIDER_API_KEY=*** COPILOT_MODEL=cheap
```

Test:
```bash
copilot -p "Reply with just: hi"
```

Expected: 1 request, 200 OK, no retries, ~3-15s depending on combo.

---

## Cursor / Continue.dev / Aider / any OpenAI-compatible tool

Same `OPENAI_BASE_URL` / `OPENAI_API_KEY` pattern as codex.

| Tool         | Base URL                       | API key env / setting   |
|--------------|--------------------------------|--------------------------|
| Aider        | `--openai-api-base` flag       | `OPENAI_API_KEY`         |
| Cursor       | Settings → Models → OpenAI API Base URL | `OPENAI_API_KEY` |
| Continue.dev | `config.json` `apiBase`        | `apiKey`                 |
| Cody         | VS Code settings, "Cody: Autocomplete" → "Server URL" | "Access Token" |

---

## Sanity check

```bash
./scripts/test-e2e.sh
```

The script tries each tool in turn and reports HTTP status + token count.
Exits 0 on all-green, 1 on any tool returning non-2xx.

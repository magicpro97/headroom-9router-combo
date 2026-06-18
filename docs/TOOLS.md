# Per-tool setup — point your tools at headroom

## TL;DR

If your tool already pointed at 9router, you change one URL:

| Was            | Now                  |
|----------------|----------------------|
| `localhost:20128` (9router) | `localhost:8787` (headroom, in front of 9router) |
| model: upstream name (`claude-sonnet-4`, `gpt-5`, ...) | model: combo name (`cheap`, `default`, whatever you set in 9router) |

That's it. 9router stays running on `:20128`; headroom just sits in
front and compresses. The tool only sees `:8787`.

> **Note about Copilot**: as of 1.0.63, GitHub Copilot CLI does not
> support a custom base URL or BYOK provider config. The only path
> from Copilot to 9router is the **MITM daemon** (`/etc/hosts`
> hijack + root CA) that 9router ships. This combo cannot intercept
> Copilot traffic — Copilot continues to use 9router's MITM
> directly. The three tools below all support explicit base URLs
> and work with the combo.

---

## Before you start

1. The combo is up. Check:
   ```bash
   curl -s http://localhost:8787/livez
   # → {"service":"headroom-proxy","status":"healthy",...}
   ```
2. 9router is up (it is, by definition, if the combo is up):
   ```bash
   curl -s http://127.0.0.1:20128/api/health
   ```
3. You have a combo name in 9router. If you don't know yours:
   ```bash
   sqlite3 ~/.9router/db/data.sqlite "SELECT name, models FROM combos;"
   # cheap|["trt/MiniMax-M3","tr/MiniMax-M3"]
   ```
   In the rest of this doc, `cheap` is used as the example combo name.
   Substitute yours.

---

## codex (OpenAI CLI)

**Env:**
```bash
export OPENAI_BASE_URL=http://localhost:8787/v1
export OPENAI_API_KEY=*** export OPENAI_MODEL=cheap
```

**Or in `~/.codex/config.toml`:**
```toml
[model]
name = "cheap"

[provider]
base_url = "http://localhost:8787/v1"
api_key = "***"
```

**Test:**
```bash
codex exec --model cheap "Reply with just: hi"
```

---

## claude-code (Anthropic CLI)

**Env:**
```bash
export ANTHROPIC_BASE_URL=http://localhost:8787
export ANTHROPIC_API_KEY=*** export ANTHROPIC_MODEL=cheap
```

**Test:**
```bash
claude -p "Reply with just: hi" --model cheap
```

---

## opencode

**Edit `~/.config/opencode/opencode.json`:**
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

**Test:**
```bash
opencode run "Reply with just: hi" -m "headroom/cheap"
```

---

## copilot (GitHub Copilot CLI) — no combo path

GitHub Copilot CLI (verified on 1.0.63) does not expose a custom
base URL or BYOK provider config. The only integration with
9router is the **MITM daemon** that 9router ships:

- 9router installs a root CA in the host keychain
- 9router patches `/etc/hosts` to redirect Copilot's normal
  endpoints to 127.0.0.1:443
- 9router's MITM proxy on :443 intercepts HTTPS, rewrites model
  names, and forwards to the configured provider

**This combo cannot intercept Copilot traffic** — headroom only
sees HTTP traffic sent to `:8787`, and Copilot sends everything to
its own endpoints (which 9router's MITM already handles).

If you want Copilot to use a different model:
1. Open the 9router GUI
2. Edit `~/.9router/mitm/aliases.json` to map Copilot's default
   model to your combo
3. Restart 9router (or just the MITM daemon)

Reference aliases from the bundled 9router install:
```json
{
  "copilot": {
    "gpt-5-mini": "trt/MiniMax-M3",
    "gpt-5.4-nano": "trt/MiniMax-M3",
    "claude-haiku-4.5": "trt/MiniMax-M3",
    "gpt-4o": "trt/MiniMax-M3",
    "gpt-4.1": "trt/MiniMax-M3"
  }
}
```

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

## Why `model=cheap` and not the upstream model name

9router's combos are an indirection layer. `cheap` is not a real
model — it's a name that resolves (in your 9router config) to one
or more `provider/model` pairs. When headroom forwards
`model=cheap` to 9router, 9router picks a real upstream.

If you point a tool directly at 9router with `model=gpt-5`, 9router
has to figure out which provider owns `gpt-5`. With the combo
indirection, you decide once (in 9router's GUI) and the tool stays
provider-agnostic.

Some tools (like codex with a non-combo `OPENAI_MODEL`) will work
without a combo if you point directly at 9router. With headroom in
front, the combo indirection is the recommended path because:
- You can swap providers without changing tool config
- You can fan out across multiple accounts (round-robin, fallback)
- 9router's combo strategy controls load distribution

---

## 9router MITM: should you disable it now?

9router's MITM (`localhost:20128` + `/etc/hosts` + root CA) is
designed to **intercept traffic from tools that don't support
custom base URLs** (notably Copilot). It sits between those tools
and their normal endpoint.

When you point a tool at `localhost:8787`, the tool is no longer
sending traffic to its normal endpoint. The MITM has nothing to
intercept (for that tool). **You can leave 9router's MITM running
— it's harmless when the tool is configured to use the combo
directly.**

The only reason to disable it:
- You're worried about `/etc/hosts` hijacks causing issues with
  other apps on the machine.
- You want to test that the tool works *without* 9router's
  MITM (pure combo path).

In the GUI: Settings → MITM → toggle off. Restart 9router for the
change to take effect.

If you disable MITM, **Copilot stops working with 9router entirely**
— there's no fallback path for Copilot.

---

## Sanity check

After configuring your tool, verify the round trip:

```bash
./scripts/test-e2e.sh
```

The script tries codex, claude-code, and opencode (the three tools
that can be pointed at headroom) and reports whether each one
received a non-empty response. Exits 0 on all-green, 1 on any
tool returning empty or non-2xx.

Manual single-tool check:
```bash
# Bypass the tool, hit the combo directly
curl -s -X POST http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"cheap","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}'
# → 200 OK with a real completion (model field shows what 9router picked)
```

If the tool fails but the direct curl works, the issue is the
tool's config (wrong env var, wrong model name, wrong base URL),
not the combo.

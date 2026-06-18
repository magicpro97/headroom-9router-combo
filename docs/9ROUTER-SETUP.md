# 9router setup for the combo

This doc covers what you need to know about 9router so the combo works.
9router is a **host-side service** that this repo does not install or manage.
You bring your own running 9router; this combo just plugs into it.

## TL;DR

1. Run 9router (host, not docker). Default port `20128`.
2. Open the GUI. Add at least one provider connection (Claude Pro,
   GitHub Copilot, OpenAI key, etc.).
3. Create a combo that maps a friendly name (e.g. `cheap`) to one or
   more provider models.
4. Start headroom. The combo is live on `http://localhost:8787`.

## What 9router is and isn't

9router is a multi-provider router for LLM APIs. It exposes an
OpenAI-compatible endpoint at `http://127.0.0.1:20128/v1` and
forwards requests to whichever provider you have configured. It
also runs a MITM TLS proxy that captures IDE traffic (Copilot,
Claude Code, Codex) and replays it through the same router.

The combo does **not** replace 9router. It adds a compression layer
(headroom) **in front of** 9router. Think of headroom as an
optimizer; 9router stays the source of truth for which provider
serves which model.

```
[tool] → headroom :8787 (compression) → 9router :20128 (routing) → provider
```

## What you configure in 9router

### 1. Provider connections

A provider connection is a credentialed account at one of the
upstream services 9router supports. Each connection has:
- a provider type (`github`, `codex`, `openrouter`, `anthropic`,
  `xai`, `ollama`, `openai-compatible-responses`, `antigravity`,
  `glm`, `qoder`, …)
- an auth type (`oauth` for IDE-style accounts, `apikey` for
  direct API keys)
- a priority and active flag
- the raw credential (token, API key, OAuth refresh token)

You can have many connections per provider type. 9router uses a
fallback strategy (default `round-robin` with `stickyRoundRobinLimit=3`)
to spread load and survive rate-limits.

To add a connection: open the 9router GUI, go to the **Providers**
tab, pick a provider, paste the credential, save. 9router validates
the credential before saving.

### 2. Combos

A combo is a friendly model name that fans out to one or more
real provider models. Example: a combo called `cheap` could map to
`trt/MiniMax-M3` and `tr/MiniMax-M3` (two model IDs that 9router
translates to the same provider account with prefix-based rotation).

This is how the combo's `OPENAI_BASE_URL=http://localhost:8787/v1`
+ `model=cheap` becomes a real upstream call: headroom forwards
`model=cheap` to 9router, 9router looks up the combo, picks a real
model, picks a connection, forwards.

To create a combo: GUI → **Combos** → New. Pick a name. Add model
IDs. Save.

You can mix providers in one combo (e.g. `claude-sonnet-4` from
Claude Pro and `gpt-5` from OpenAI in the same `default` combo) and
9router will rotate.

### 3. Fallback strategy

For each provider, 9router picks the next connection based on a
strategy. The default is **round-robin with a sticky limit**: it
sends N requests to the same connection before rotating. This keeps
most chatty multi-turn conversations on the same account, which is
what most providers want.

Settings live in the `settings` table of 9router's SQLite. Edit
via the GUI (Settings tab) or directly via `sqlite3` if you know
what you're doing.

### 4. MITM (Copilot / Claude Code / Codex)

9router's MITM is what makes "send IDE traffic through 9router" work.
It installs a root CA, hijacks `/etc/hosts` for the relevant domains,
and decrypts HTTPS requests to inject a chosen model. This is
**why 9router must run on the host** (root + `/etc/hosts` access).

This is also why the combo's `docker-compose.yml` does **not**
include 9router. The combo assumes 9router is already running on
the host at `:20128`.

## What 9router does NOT need from the combo

- No API key. The combo's `--openai-api-key` is a placeholder
  string; 9router does not validate it (loopback access is
  un-authenticated by default).
- No special config to forward to headroom. 9router only sees
  `http://host:20128/v1`; it doesn't know headroom exists.

## Health checks

9router alive:
```bash
curl -s http://127.0.0.1:20128/api/health
# → {"status":"ok",...}  (varies by version)
```

9router can talk to a provider (round-trip a chat completion):
```bash
curl -s -X POST http://127.0.0.1:20128/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"cheap","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}'
# → 200 OK with content from the configured provider
```

Combo alive (headroom in front of 9router):
```bash
curl -s http://localhost:8787/livez
# → {"service":"headroom-proxy","status":"healthy",...}
```

Full pipeline round-trip:
```bash
curl -s -X POST http://localhost:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"cheap","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}'
# → 200 OK, model field shows what 9router picked (e.g. "MiniMax-M3")
```

## Common 9router config issues with the combo

| Symptom | Cause | Fix |
|---------|-------|-----|
| `401 "API key required for remote API access"` from 9router | request from non-loopback IP (docker bridge, external network) | run headroom as a host process on macOS, or use `network_mode: host` on Linux |
| 9router returns the requested model name, not the combo's resolved model | 9router's combo lookup bypassed because headroom strips the `combo` hint | set `model=cheap` (the combo name) in your tool config, not the upstream model name |
| 9router returns 503 for `cheap` after restart | upstream connection cold-start | retry after 5–10 s; the combo auto-recovers |
| `headroom` returns 502 with "upstream connect error" | 9router not running | `pgrep -f 9router`; restart it |

## Why no 9router in `docker-compose.yml` here

See `WHY-NO-DOCKER-9ROUTER.md`. Short version: 9router's MITM daemon
needs root, `/etc/hosts` writes, and a host filesystem SQLite.
Docker cannot satisfy all three without breaking the very features
that make 9router useful.

This combo treats 9router as a **prerequisite host service**, the
same way 9router treats the upstream providers as external services.

## File locations (host, not in this repo)

```
~/.9router/
├── auth/
│   └── cli-secret         # CLI auth secret
├── bin/
│   └── cloudflared        # tunnel binary
├── db/
│   └── data.sqlite        # all config: providers, combos, usage, settings
├── jwt-secret
├── logs/
├── machine-id
├── mitm/
│   ├── aliases.json       # copilot model → combo mapping
│   └── rootCA.crt         # MITM root cert
├── runtime/
│   ├── package.json
│   └── node_modules/      # next-server
└── tunnel/
    └── state.json
```

## Backup

9router has its own backup system. Backups land in
`~/.9router/db/backups/upgrade-X-to-Y-<ts>/data.sqlite`.

If you ever need to migrate the combo to another machine: copy
`~/.9router/` (excluding `runtime/node_modules/` and
`mitm/rootCA.crt` if the new machine has its own MITM state).

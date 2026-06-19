# headroom + 9router combo

Single entry point for **codex**, **claude-code**, **opencode**, **copilot** (and any
OpenAI/Anthropic-compatible tool) that compresses context before it hits 9router.

```
[tool] ──► headroom :8787 ──► 9router :20128 ──► upstream (any provider)
```

- **headroom** (LLM context compression proxy) — cuts token cost 50-90% via smart
  tool-output / log / RAG compression.
- **9router** (multi-provider router) — aliases, combos, fallbacks, health-aware
  routing across OpenAI / Anthropic / Gemini / local models.

Both run on `localhost`. The tool only sees one URL: `http://localhost:8787`.

---

## Architecture

```
┌────────────┐   http    ┌──────────────────┐   http    ┌──────────────┐
│   tool     │ ────────► │   headroom       │ ────────► │   9router    │ ───► upstream
│ (codex,    │  :8787    │ (compression     │  :20128   │ (combo       │
│  claude-   │           │  passthrough)    │           │  routing)    │
│  code, …)  │ ◄──────── │                  │ ◄──────── │              │
└────────────┘  SSE/JSON └──────────────────┘  SSE/JSON └──────────────┘
```

- **headroom** is the only thing in this repo. 9router is treated as a host
  dependency — see `docs/WHY-NO-DOCKER-9ROUTER.md`.
- Headroom forwards every request to 9router. Compression is **off** by default
  in the Quick-Start passthrough recipe; the macOS launchd production setup
  below runs it **on** (`--mode token --code-aware`). See "Compression: when it
  actually fires".
- 9router resolves combo names (e.g. `cheap` → `trt/MiniMax-M3+tr/MiniMax-M3`)
  and model aliases on the upstream side. Headroom is protocol-agnostic.

---

## Quick start

### 1. Prereqs

- macOS / Linux host with **Docker Desktop** (or Docker Engine + Compose v2)
- **9router** running locally on `0.0.0.0:20128` (default port; do not stop it)
- One of: `codex`, `claude`, `opencode`, `copilot`

### 2. Start the combo

**macOS** (recommended — host process):

```bash
# All features (default) — litellm + 9router, --learn, --code-aware, --memory, cache, rate-limit, telemetry
~/work/headroom-9router-combo/scripts/start.sh

# Passthrough (no extra LLM calls, no token savings, no cache)
COMPRESSION_MODE=passthrough ~/work/headroom-9router-combo/scripts/start.sh

# Disable code-aware or memory individually
CODE_AWARE=0 ~/work/headroom-9router-combo/scripts/start.sh
MEMORY=0 ~/work/headroom-9router-combo/scripts/start.sh
```

Manual equivalent:

```bash
# All features (default — needs `pip install 'headroom-ai[code]'` for tree-sitter)
headroom proxy --host 0.0.0.0 --port 8787 --workers 1 \
  --backend litellm-openai --learn --code-aware --memory \
  --openai-api-url http://127.0.0.1:20128/v1 \
  --anthropic-api-url http://127.0.0.1:20128/v1 \
  --cloudcode-api-url http://127.0.0.1:20128/v1 &
curl -s http://localhost:8787/livez | jq

# Passthrough (no compression, no cache, no rate limit, no code-aware, no memory)
headroom proxy --host 0.0.0.0 --port 8787 --workers 1 \
  --no-optimize --no-cache --no-rate-limit \
  --openai-api-url http://127.0.0.1:20128/v1 \
  --anthropic-api-url http://127.0.0.1:20128/v1 \
  --cloudcode-api-url http://127.0.0.1:20128/v1 &
```

### One-time setup for full features

The default `--code-aware` requires tree-sitter (~2 MB). `--memory` with
semantic search requires hnswlib + sentence-transformers + torch
(~2 GB disk, ~1.5 GB RSS at startup, ~80 MB model auto-downloaded).

```bash
pip3 install --user 'headroom-ai[code,memory]'
```

**Memory with semantic search** is what you want when you have many
projects and want to retrieve relevant context across them. Without
the `[memory]` extra, headroom falls back to exact-match search via
sqlite-vec — still works, just less "smart" at scale.

**Linux** (docker compose, host network profile):

```bash
cp .env.example .env       # edit if 9router is on a different host/port
COMPOSE_PROFILES=host docker compose up -d
curl -s http://localhost:8787/livez | jq
```

**Any host** (docker compose, bridge profile, requires 9router API key):

```bash
cp .env.example .env
# Edit .env: set ROUTER_API_KEY=... matching the value in 9router's env
docker compose --profile bridge up -d
```

### 3. Point your tools at the combo

| Tool          | Env var                          | Value                                  |
|---------------|----------------------------------|----------------------------------------|
| codex         | `OPENAI_BASE_URL`                | `http://localhost:8787/v1`             |
| claude-code   | `ANTHROPIC_BASE_URL`             | `http://localhost:8787`                |
| opencode      | `~/.config/opencode/opencode.json` (provider) | see `docs/TOOLS.md`            |
| copilot       | `COPILOT_PROVIDER_BASE_URL`      | `http://localhost:8787/v1`             |

Per-tool recipe in `docs/TOOLS.md`.

### 4. Verify end-to-end

```bash
./scripts/test-e2e.sh
# → 4/4 tools respond with HTTP 200, no retries
```

---

## Production setup (macOS, launchd, verified 2026-06-19)

The Quick Start runs headroom as a foreground/`&` host process — it dies on
logout or reboot. For a always-on setup, register the services with `launchd`
so they auto-start at boot and auto-restart on crash. This is the layout
running in production:

```
┌──────────────┐
│ Claude Code  │  ANTHROPIC_BASE_URL=http://127.0.0.1:8787
│ Codex /      │  OPENAI_BASE_URL=http://127.0.0.1:8787/v1
│ OpenCode     │
└──────┬───────┘
       ▼
┌──────────────────────────┐  com.<org>.headroom-front  (KeepAlive)
│ headroom FRONT  :8787    │  --backend anthropic --mode token --code-aware
│ compression + AST        │  --openai-api-url http://127.0.0.1:20128/v1
└──────┬───────────────────┘  --anthropic-api-url http://127.0.0.1:20128/v1
       ▼
┌──────────────────────────┐  host process (its own launchd / autostart)
│ 9router         :20128   │  aliases · combos · provider OAuth
└──┬────────┬─────────┬────┘
   │ gh/*   │ tr/*    │ hr/* · sonnet · haiku · bedrock-combo
   │copilot │tokenrtr │        ▼
   ▼        ▼         ┌──────────────────────────┐  com.<org>.headroom-bedrock (KeepAlive)
 OAuth   tokenrouter  │ headroom BEDROCK  :8789  │  --backend bedrock
                      │ STS auto-refresh bridge  │  --bedrock-client-hook bedrock_refresh:make_client
                      └──────┬───────────────────┘
                             ▼
                      AWS Bedrock Tokyo (ap-northeast-1, jp.anthropic.*)
```

### Two headroom instances, different jobs

| Port | Role | Backend | Who hits it |
|------|------|---------|-------------|
| **8787** | front door / compression gateway | `anthropic` (+ `--openai-api-url`/`--anthropic-api-url` → 9router) | every tool you point at the combo |
| **8789** | Bedrock STS bridge | `bedrock` + `--bedrock-client-hook` | 9router, only for `hr/*` / `sonnet` / `haiku` / `bedrock-combo` |

Copilot (`gh/*`) and TokenRouter (`tr/*`) traverse headroom **once** (8787).
Bedrock models traverse it **twice** (8787 compress-front, 8789 STS-bridge) —
8789 exists only because 9router cannot auto-refresh STS itself. The
`--bedrock-client-hook` is the upstream PR
[chopratejas/headroom#1104](https://github.com/chopratejas/headroom/pull/1104).

### STS auto-refresh is two parts, not one

A static STS profile (no SSO / `credential_process`) expires every 1 h. The
8789 hook's `RefreshableCredentials` can only re-read `~/.aws/credentials` —
which itself dies in 1 h. So you ALSO need a periodic job that re-mints creds
(e.g. an ADFS→STS CLI on a 45-min `StartInterval`). KeepAlive on the proxy is
**not** enough on its own.

| launchd label | role | KeepAlive |
|---------------|------|-----------|
| `com.<org>.sts-refresh` | re-mint STS into `~/.aws/credentials` every 45 min | false (one-shot) |
| `com.<org>.headroom-bedrock` | port 8789, `--backend bedrock` + hook | true |
| `com.<org>.headroom-front` | port 8787, `--backend anthropic` → 9router | true |

Wrapper scripts + plist templates: see `launchd/` (copy, set your paths, then
`launchctl load -w ~/Library/LaunchAgents/com.<org>.<svc>.plist`).

### ⚠️ Self-host hazard — never route a self-hosted agent through a port it administers

If the agent that manages these services also uses the combo for its OWN LLM
calls (e.g. Hermes with `model.base_url=http://127.0.0.1:8787`), then killing/
restarting 8787 to reconfigure it **severs that agent's own live connection
mid-task**. Keep the managing agent's lifeline on a port it will not bounce
(9router `:20128` direct), and use 8787 only for the *other* tools (Claude
Code, Codex). Before any `kill`/`launchctl` on a proxy port, check what your
agent's base URL points at first.

### Compression: when it actually fires

`--mode token --code-aware` is real compression (not passthrough), but it only
kicks in on **agent workloads** — many tool outputs, file reads, logs, long
conversation history. A single one-shot prompt shows `requests_compressed: 0`
(nothing compressible). Verified on a real Claude Code session: 21 requests →
14 compressed, 162 K tokens seen, ~7 K removed. Code-search / log-heavy flows
hit the headline 47-92 %; lock-file / plain-prose reads compress far less.
Check `curl -s http://127.0.0.1:8787/stats | jq .summary.compression`.

### Claude Code → Bedrock through the combo

```json
// ~/.claude/settings.json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787",
    "ANTHROPIC_AUTH_TOKEN": "sk_9router",
    "ANTHROPIC_MODEL": "sonnet",
    "ANTHROPIC_SMALL_FAST_MODEL": "haiku"
  }
}
```

- Do **NOT** set `CLAUDE_CODE_USE_BEDROCK=1` — it makes Claude Code call the AWS
  SDK directly and bypasses headroom + 9router entirely.
- Do **NOT** set `AWS_*` here — STS is handled by the 8789 bridge, Claude Code
  never touches AWS.
- `sonnet` → `jp.anthropic.claude-sonnet-4-6`, `haiku` → `jp.anthropic.claude-haiku-4-5`.
- Opus is policy-blocked on this Bedrock account; use Copilot `gh/claude-opus-4.8`
  via 9router for Opus instead.

---
## Files

```
docker-compose.yml         headroom service definition
.env.example               9router URL template
docs/ARCHITECTURE.md       packet flow + per-hop responsibilities
docs/TOOLS.md              per-tool env vars and config snippets
docs/9ROUTER-SETUP.md      what to configure in 9router for the combo
docs/WHY-NO-DOCKER-9ROUTER.md  why 9router runs on the host, not in docker
scripts/start.sh           docker compose up -d + wait-for-healthy
scripts/stop.sh            docker compose down
scripts/test-e2e.sh        smoke-test all 4 tools
launchd/                   macOS always-on templates (front + bedrock-bridge + sts-refresh)
```

---

## Why no headroom service in 9router?

It would force every 9router user to install Docker, pin a specific headroom
version, and break the "9router is a single binary" property. Instead, headroom
sits in front as an *optional* compression layer. Drop it and 9router works
exactly as before.

---

## 9router auth gotcha: source-IP check

9router returns `401 {"error":"API key required for remote API access"}` when
the request comes from a non-loopback IP. This bites every containerised
deployment because Docker bridge networking gives containers a `172.x` IP that
9router sees as "remote".

**Three ways to fix:**

| Profile              | Setup                                                        | Use when                                  |
|----------------------|--------------------------------------------------------------|-------------------------------------------|
| `host` (compose)     | `network_mode: host` so headroom sees host loopback          | **Linux only** — Mac Docker Desktop runs in a VM, so `host` doesn't actually share netns |
| `bridge` (compose)   | Set `ROUTER_API_KEY` in 9router env, pass `OPENAI_API_KEY=…` to headroom | Any host, requires 9router restart to set the key |
| Host process (no docker) | `pip install headroom-ai && headroom proxy …`             | macOS / when you don't want docker at all |

This repo defaults to **`bridge` + API key** (most portable). On macOS the
simplest path is to run headroom as a host process — see the Quick Start note
below.

### macOS quick start (no docker networking drama)

```bash
pip3 install --user 'headroom-ai[proxy]'
export PATH="$HOME/Library/Python/3.12/bin:$PATH"
headroom proxy --host 0.0.0.0 --port 8787 --workers 1 --no-optimize --no-cache \
  --openai-api-url http://127.0.0.1:20128/v1 \
  --anthropic-api-url http://127.0.0.1:20128/v1 \
  --cloudcode-api-url http://127.0.0.1:20128/v1 &
```

The `docker-compose.yml` is here for Linux users and CI. On macOS, prefer
the host process — Docker Desktop's `network_mode: host` is not a real
host network, so it doesn't help.

---

## License

MIT for this repo. headroom is Apache-2.0, 9router is closed-source — see
their respective repos.

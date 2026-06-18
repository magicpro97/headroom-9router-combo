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
  in this combo (passthrough). Flip `HEADROOM_NO_OPTIMIZE=0` once you wire your
  own provider keys into headroom's auth path.
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

The default `--code-aware` requires tree-sitter (~2 MB). Memory uses
headroom's built-in SQLite (per-project, no qdrant needed).

```bash
pip3 install --user 'headroom-ai[code]'
```

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

## Files

```
docker-compose.yml         headroom service definition
.env.example               9router URL template
docs/ARCHITECTURE.md       packet flow + per-hop responsibilities
docs/TOOLS.md              per-tool env vars and config snippets
docs/WHY-NO-DOCKER-9ROUTER.md  why 9router runs on the host, not in docker
scripts/start.sh           docker compose up -d + wait-for-healthy
scripts/stop.sh            docker compose down
scripts/test-e2e.sh        smoke-test all 4 tools
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

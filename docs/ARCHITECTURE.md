# Architecture

## Packet flow

```
client tool
   │
   │  ① HTTP POST /v1/chat/completions
   │     (or /v1/messages, /v1/responses)
   ▼
headroom :8787
   │
   │  • auth_mode classifier (PAYG / OAuth / SUBSCRIPTION)
   │  • compression pipeline (OFF in this combo — passthrough)
   │  • X-Headroom-* header injection (also OFF in passthrough)
   │
   │  ② HTTP POST <NINE_ROUTER_BASE>/v1/...
   ▼
9router :20128
   │
   │  • model name resolution (alias → real model, combo expansion)
   │  • provider selection (alias, health, fallback)
   │  • upstream auth (key management is here)
   │
   │  ③ HTTPS to upstream (OpenAI / Anthropic / Gemini / local)
   ▼
upstream
```

## Per-hop responsibilities

### headroom
- **In**: every OpenAI Chat Completions / Anthropic Messages / Codex Responses request
- **Out**: identical request, unchanged body, unchanged streaming
- **What it does here**: nothing (passthrough mode). With compression ON, it
  rewrites `messages[].content` and injects cache-control markers.
- **Why in front**: future-proofing. The same combo can later compress
  tool outputs from `codex --full-stdout` flows without changing the tool.

### 9router
- **In**: model name string + auth header
- **Out**: provider-specific request, possibly translated across protocols
  (OpenAI Chat ↔ Anthropic Messages)
- **What it does here**:
  - Expand combo name `cheap` → `[trt/MiniMax-M3, tr/MiniMax-M3]` and pick
    the first healthy one
  - Translate `claude-sonnet-4.5` (Anthropic-style) → OpenAI Chat Completions
    if the upstream only supports OpenAI
  - Apply `ROUTER_API_KEY` if set
- **Why not also in docker**: see `WHY-NO-DOCKER-9ROUTER.md`.

## Failure modes

| Hop down    | Tool sees                                | Recovery                          |
|-------------|------------------------------------------|-----------------------------------|
| headroom    | `connection refused` on `:8787`          | `docker compose up -d`            |
| 9router     | headroom returns 401 / 502               | restart 9router (host service)    |
| upstream    | headroom returns 5xx (no retry by default) | flip combo fallback in 9router   |

## What lives where

- `docker-compose.yml` — headroom service only
- `~/.9router/runtime/...` — 9router runtime, host process, untouched
- Tool config files (`~/.config/opencode/`, `~/.copilot/`, `~/.codex/`) — env vars only, no install

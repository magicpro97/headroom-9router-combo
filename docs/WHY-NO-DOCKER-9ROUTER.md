# Why 9router is **not** in this docker-compose

**Short version**: 9router has a MITM TLS-intercept daemon that needs root,
host network namespaces, and a trusted root CA. None of those survive being
slapped into a container without breaking the very features that make 9router
useful.

## What 9router actually runs

```
9router tray (node, GUI) ── spawns ──► 9router next-server :20128
                                   └─► 9router MITM :443  (root, /etc/hosts hijack)
                                   └─► cloudflared tunnel (host binary)
                                   └─► sqlite db (host fs, $HOME/.9router)
```

## Why each piece fights docker

| Component         | Needs                                                | Docker breaks it                                |
|-------------------|------------------------------------------------------|-------------------------------------------------|
| MITM daemon       | `CAP_NET_ADMIN` + iptables hijack + trusted CA       | needs `--cap-add=NET_ADMIN --network=host`, CA trust lost on every container restart |
| Root CA install   | system keychain (macOS) / `/usr/local/share/ca-certificates` (Linux) | container CA invisible to host trust store     |
| `/etc/hosts` hijack | DNS resolution for `api.individual.githubcopilot.com` | requires host filesystem mount, fragile        |
| `cloudflared`     | host binary, host auth, host DNS                     | can run in container but loses access to host's tunnel state |
| `sqlite` db       | `$HOME/.9router/db/data.sqlite`                      | volume-mount works but breaks tray UX           |
| Tray icon         | macOS menu-bar                                       | impossible in Linux container                   |

The MITM layer is the killer. It works by:

1. Generating a root CA in `~/.9router/mitm/rootCA.crt`
2. Installing it in the OS trust store (Keychain on macOS)
3. Hijacking DNS for `*.githubcopilot.com` / `*.openai.com` / etc.
4. Listening on `:443` with `root` so it can bind the privileged port
5. Forging leaf certs per hostname and proxying to the real upstream

Step 1-4 require the host. A container doing it would either:
- Run with `--network=host --cap-add=NET_ADMIN --cap-add=SYS_ADMIN` — at which
  point you don't get isolation, you get a glorified chroot
- Or stay in the bridge network, in which case the trust store in the container
  is not consulted by the host browser / tool, so MITM doesn't work

## The "just put 9router in a container" trap

People have tried. The result is a 600-line docker-compose that needs
`--privileged`, a custom network namespace, a `bind` mount of `/etc/ssl/certs`
and `/etc/hosts`, and a post-install hook to re-trust the CA every time the
container starts. The image weighs 1.2 GB because it ships the full Node
runtime + native deps, and updates require rebuilding the whole stack.

You'd save nothing and break 9router's ability to MITM your real IDE traffic
(Copilot in VS Code, Codex CLI, Claude Code's OAuth flow).

## What this repo does instead

- **Treat 9router as a host-side service.** It already has its own updater,
  tray, MITM daemon, and key rotation. Don't fight it.
- **Put headroom in front.** headroom is a stateless passthrough proxy — the
  exact shape that fits well in a container. It binds 8787, forwards to the
  host's 20128, and adds nothing to the host's trust store.
- **The combo entry point is `:8787` for tools.** When tools see
  `http://localhost:8787`, they reach headroom, which reaches 9router, which
  reaches the real provider. Headroom can be down without breaking 9router;
  9router can be restarted without rebuilding this stack.

## When you might want a different shape

- **If 9router ever ships a `--headless` mode** (no tray, no MITM, just
  next-server on 20128), then dockerizing it becomes reasonable. The MITM
  becomes a separate `9router-mitm` service, and the rest can sit in a
  container like headroom does.
- **If you're using only the 9router HTTP API** (BYOK, no MITM) — same
  answer, `--headless` would make it work. The combo would become a
  2-service compose (`9router + headroom`).
- **If you only need headroom** (no 9router) — then the compose is just
  headroom with `OPENAI_TARGET_API_URL` pointed straight at OpenAI. Trivial
  to switch via the env var in `.env`.

For now, the constraint is: 9router lives on the host, headroom lives in
docker, and the two talk over `host.docker.internal:20128`.

## See also

- `ARCHITECTURE.md` — packet flow
- `README.md` — quick start

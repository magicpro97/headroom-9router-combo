# launchd templates — always-on combo on macOS

These are templates. Copy them, replace the placeholders, then load.

Placeholders:
- `<ORG>`        — a reverse-DNS prefix for the launchd label, e.g. `com.acme`
- `<COMBO_DIR>`  — absolute path to this repo, e.g. `/Users/you/work/headroom-9router-combo`
- `<HEADROOM_FRONT_BIN>`  — headroom binary used for the front proxy (PyPI install is fine)
- `<HEADROOM_BEDROCK_BIN>`— headroom binary with the `--bedrock-client-hook` patch (PR #1104 / fork)
- `<STS_REFRESH_CMD>`     — your ADFS/SSO→STS command that rewrites `~/.aws/credentials`
- `<BEDROCK_REFRESH_PYPATH>` — dir containing your `bedrock_refresh.py` hook module (added to PYTHONPATH). This repo ships the hook at `launchd/bedrock_refresh.py`, so this is usually `<COMBO_DIR>/launchd`.
- `<AWS_PROFILE>` / `<AWS_REGION>` — your Bedrock profile + region

## The Bedrock STS auto-refresh hook (`bedrock_refresh.py`)

`launchd/bedrock_refresh.py` is the `--bedrock-client-hook` module the 8789
proxy loads (`--bedrock-client-hook bedrock_refresh:make_client`). It hands
headroom a boto3 `bedrock-runtime` client backed by
`botocore.credentials.RefreshableCredentials`, so the 1-hour STS rollover
becomes invisible — no 50-min proxy restart.

How it works:
- `make_client(region)` seeds creds once, then wires a `RefreshableCredentials`
  onto the **inner botocore session** (`session._session._credentials`). litellm
  keeps the same client object and it re-signs each SigV4 request with creds
  re-resolved on demand.
- `_refresh_credentials()` shells out to `aws configure export-credentials
  --format env` and parses `aws_session_expiration` from `~/.aws/credentials`.
  It caches on file mtime + expiry, so it does not hammer the CLI on every call,
  but picks up an external rewrite immediately.

It is configured purely by env (set in `headroom-bedrock.sh`):
`AWS_PROFILE`, `AWS_REGION`, `HEADROOM_BEDROCK_EXPIRY_WINDOW` (default 300s),
and optional `STS_REFRESH_CMD` (a command that re-mints STS into
`~/.aws/credentials`; the hook runs it only when the file is already expired,
to self-heal a missed `sts-refresh` tick).

Two-part refresh, not one: `RefreshableCredentials` can only *re-read* the
file. Something else must keep `~/.aws/credentials` itself fresh — that's the
`sts-refresh` launchd job on a 45-min `StartInterval`. KeepAlive on the proxy
is **not** enough on its own.

> **The dead-write gotcha** (the one bug worth knowing): the creds MUST go on
> `session._session._credentials`, not `session._credentials`. The boto3 wrapper
> attribute is never read by the signer; setting it silently drops the
> refreshable creds and the client falls back to static env creds (`expiry=None`)
> that die at the first rollover. A freshly started proxy looks healthy for the
> first ~1h seed window either way, so a single live request does NOT prove the
> refresh works.

Verify without AWS / network (stubs boto3, exits non-zero on regression):

```bash
python3 launchd/verify_bedrock_refresh.py
```

Needs the fork / PR #1104 build of headroom (`<HEADROOM_BEDROCK_BIN>`) that
exposes `--bedrock-client-hook`; PyPI headroom does not have it.

## Install

```bash
mkdir -p ~/.local/combo-services ~/.local/combo-services/logs
# 1. copy the three .sh wrappers, edit placeholders, chmod +x
cp launchd/*.sh ~/.local/combo-services/ && chmod +x ~/.local/combo-services/*.sh
# 2. copy the three .plist files, edit placeholders + ProgramArguments path
cp launchd/*.plist ~/Library/LaunchAgents/
# 3. load
for s in sts-refresh headroom-bedrock headroom-front; do
  launchctl load -w ~/Library/LaunchAgents/<ORG>.$s.plist
done
launchctl list | grep <ORG>     # pid / last-exit
```

## Notes

- Only need the **front** service (8787) if you just want compression in front
  of 9router. The **bedrock** (8789) + **sts-refresh** services are only for the
  AWS Bedrock STS-bridge path — skip them if you don't route Bedrock models.
- `KeepAlive=true` restarts the proxy if it dies. `sts-refresh` is a one-shot
  (`KeepAlive=false`) on a 45-min `StartInterval`.
- The front proxy tolerates a cold 9router (returns 502 until 9router answers),
  so no hard launchd ordering is needed.
- See the README "Production setup" section for the full architecture and the
  self-host hazard warning.

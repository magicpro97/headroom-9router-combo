# launchd templates — always-on combo on macOS

These are templates. Copy them, replace the placeholders, then load.

Placeholders:
- `<ORG>`        — a reverse-DNS prefix for the launchd label, e.g. `com.acme`
- `<COMBO_DIR>`  — absolute path to this repo, e.g. `/Users/you/work/headroom-9router-combo`
- `<HEADROOM_FRONT_BIN>`  — headroom binary used for the front proxy (PyPI install is fine)
- `<HEADROOM_BEDROCK_BIN>`— headroom binary with the `--bedrock-client-hook` patch (PR #1104 / fork)
- `<STS_REFRESH_CMD>`     — your ADFS/SSO→STS command that rewrites `~/.aws/credentials`
- `<BEDROCK_REFRESH_PYPATH>` — dir containing your `bedrock_refresh.py` hook module (added to PYTHONPATH)
- `<AWS_PROFILE>` / `<AWS_REGION>` — your Bedrock profile + region

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

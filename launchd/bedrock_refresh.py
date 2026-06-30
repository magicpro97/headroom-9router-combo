"""Bedrock client factory hook for Headroom — auto-refreshing STS credentials.

This is the module referenced by ``launchd/headroom-bedrock.sh`` as
``--bedrock-client-hook bedrock_refresh:make_client``. Put the directory that
holds this file on ``PYTHONPATH`` (the wrapper script does this via
``<BEDROCK_REFRESH_PYPATH>``), then start the fork build of headroom:

    PYTHONPATH=/path/to/headroom-9router-combo/launchd \\
    AWS_PROFILE=myprofile AWS_REGION=ap-northeast-1 \\
    headroom proxy \\
        --backend bedrock \\
        --region ap-northeast-1 \\
        --bedrock-client-hook bedrock_refresh:make_client

Requires the fork / PR #1104 build of headroom that exposes
``--bedrock-client-hook`` (https://github.com/chopratejas/headroom/pull/1104).

Why this exists
---------------
A static STS profile (no SSO / ``credential_process``) expires every ~1 h.
Restarting headroom every hour adds a short outage each time. This hook hands
headroom a boto3 ``bedrock-runtime`` client backed by
``botocore.credentials.RefreshableCredentials`` so STS rotation becomes
invisible: litellm keeps the same client object and it re-signs each SigV4
request with freshly-resolved credentials.

NOTE: ``RefreshableCredentials`` can only *re-read* ``~/.aws/credentials``.
Something else must keep that FILE fresh (e.g. an ADFS/SSO→STS command on a
45-min ``StartInterval`` — see ``launchd/sts-refresh.sh``). Set
``STS_REFRESH_CMD`` below to let this hook self-heal a missed refresh tick.

Config (env vars)
-----------------
- ``AWS_PROFILE``  — profile to export creds from (default: ``default``)
- ``AWS_REGION``   — Bedrock region            (default: ``us-east-1``)
- ``HEADROOM_BEDROCK_EXPIRY_WINDOW`` — seconds before expiry to refresh (default 300)
- ``STS_REFRESH_CMD`` — optional shell command that re-mints STS into
  ``~/.aws/credentials``; run by this hook when the file is already expired.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import Any

# Lazy imports: keep a clear error if the operator forgot the bedrock extra.
try:
    import boto3
    from botocore.credentials import RefreshableCredentials
except ImportError as exc:  # pragma: no cover - operator error
    raise ImportError(
        "bedrock_refresh hook requires boto3 + botocore. "
        'Install with: pip install "headroom-ai[proxy,bedrock]" boto3'
    ) from exc


AWS_PROFILE = os.environ.get("AWS_PROFILE", "default")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
# Refresh this many seconds before expiry. The export-credentials shell-out is
# cheap, so a conservative window (vs boto3's stock 900 s) is fine.
EXPIRY_WINDOW_SECONDS = int(os.environ.get("HEADROOM_BEDROCK_EXPIRY_WINDOW", "300"))
# Optional: a command that re-mints STS into ~/.aws/credentials (ADFS/SSO/etc).
# Run only when the credentials file is already expired, so the hook self-heals
# a missed external refresh tick instead of serving dead creds.
STS_REFRESH_CMD = os.environ.get("STS_REFRESH_CMD")

# File-mtime cache. An external refresher rewrites ~/.aws/credentials
# periodically. If the mtime is unchanged since our last successful export, the
# contents are still the ones we parsed — skip the shell-out. Process-local; a
# headroom restart resets it (intended).
_LAST_MTIME: float | None = None
_LAST_CREDS: dict | None = None


def _read_expiration_from_credentials_file(profile: str) -> str | None:
    """Return ``aws_session_expiration`` for ``profile`` from
    ``~/.aws/credentials``, or None if the file/profile/line is missing."""
    creds_path = os.path.expanduser("~/.aws/credentials")
    if not os.path.exists(creds_path):
        return None
    in_section = False
    with open(creds_path) as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                in_section = stripped == f"[{profile}]"
                continue
            if not in_section:
                continue
            if "=" in stripped and stripped.lower().startswith("aws_session_expiration"):
                _, _, v = stripped.partition("=")
                return v.strip()
    return None


def _refresh_credentials() -> dict[str, str]:
    """Re-derive a fresh STS session by shelling out to the AWS CLI.

    Returns the metadata dict botocore expects from
    ``RefreshableCredentials._refresh_using``:
    ``access_key`` / ``secret_key`` / ``token`` / ``expiry_time``.

    Optimization: short-circuit when ``~/.aws/credentials`` mtime is unchanged
    since the last successful export AND the cached expiry is still in the
    future. Avoids hammering ``aws configure export-credentials`` on every
    request while picking up external rewrites immediately on the next call.
    """
    global _LAST_MTIME, _LAST_CREDS

    creds_path = os.path.expanduser("~/.aws/credentials")
    try:
        current_mtime = os.path.getmtime(creds_path)
    except OSError:
        current_mtime = None

    if (current_mtime is not None
        and _LAST_MTIME is not None
        and current_mtime == _LAST_MTIME
        and _LAST_CREDS is not None):
        # File unchanged AND cached creds still valid -> skip the shell-out.
        # The expiry guard is critical: if the external refresher missed a
        # cycle the cached creds go stale but the file is also stale (no
        # rewrite), so mtime alone would silently return expired creds.
        from datetime import datetime, timezone
        try:
            cached_expiry = datetime.fromisoformat(
                _LAST_CREDS["expiry_time"].replace("Z", "+00:00")
            )
        except (KeyError, ValueError):
            cached_expiry = None
        if cached_expiry is not None and cached_expiry > datetime.now(timezone.utc):
            return _LAST_CREDS

    # File already expired -> run the operator's refresh command (if any)
    # before re-reading. Covers a missed cron tick (e.g. host slept); the hook
    # self-heals on the next call. Skipped entirely when STS_REFRESH_CMD unset.
    if STS_REFRESH_CMD:
        exp = _read_expiration_from_credentials_file(AWS_PROFILE)
        if exp:
            from datetime import datetime, timezone
            try:
                if datetime.fromisoformat(exp.replace("Z", "+00:00")) <= datetime.now(timezone.utc):
                    subprocess.run(STS_REFRESH_CMD, shell=True, timeout=120)
            except (ValueError, OSError, subprocess.SubprocessError):
                pass

    if shutil.which("aws") is None:
        raise RuntimeError(
            "aws CLI is required by bedrock_refresh but was not found in PATH."
        )

    # ``--format process`` returns Expiration directly but needs awscli >= 2.17
    # (and was missing Expiration in some 2.35.x builds). ``--format env`` works
    # everywhere; we parse ~/.aws/credentials for the aws_session_expiration line.
    completed = subprocess.run(
        ["aws", "--profile", AWS_PROFILE,
         "configure", "export-credentials", "--format", "env"],
        check=True, capture_output=True, text=True,
    )

    parsed: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        if "=" not in line:
            continue
        # The env format prefixes each line with ``export ``; strip it.
        stripped = line.removeprefix("export ").lstrip()
        k, v = stripped.split("=", 1)
        parsed[k] = v.strip("'\"")
        os.environ[k] = parsed[k]  # also drop into env so litellm sees it

    if "AWS_ACCESS_KEY_ID" not in parsed or "AWS_SESSION_TOKEN" not in parsed:
        raise RuntimeError(
            f"aws configure export-credentials did not return session "
            f"credentials (got keys: {list(parsed.keys())}). Make sure profile "
            f"{AWS_PROFILE!r} uses STS (SSO or credential_process)."
        )

    if "AWS_SESSION_EXPIRATION" not in parsed:
        expiry = _read_expiration_from_credentials_file(AWS_PROFILE)
        if expiry:
            parsed["AWS_SESSION_EXPIRATION"] = expiry

    expiry = parsed.get("AWS_SESSION_EXPIRATION", "")
    if not expiry:
        raise RuntimeError(
            "AWS_SESSION_EXPIRATION missing from export-credentials output. "
            "Refresh your STS session (aws sso login / your ADFS command)."
        )
    # Normalize to RFC 3339 with a trailing Z so botocore's ISO parser is happy.
    if expiry.endswith("+00:00"):
        expiry = expiry[:-6] + "Z"
    elif expiry.endswith("+0000"):
        expiry = expiry[:-5] + "Z"

    result = {
        "access_key": parsed["AWS_ACCESS_KEY_ID"],
        "secret_key": parsed["AWS_SECRET_ACCESS_KEY"],
        "token": parsed["AWS_SESSION_TOKEN"],
        "expiry_time": expiry,
    }
    if current_mtime is not None:
        _LAST_MTIME = current_mtime
        _LAST_CREDS = result
    return result


def make_client(region: str | None) -> Any:
    """Build a ``bedrock-runtime`` boto3 client with refreshable STS creds."""
    initial = _refresh_credentials()  # seed the cache

    creds = RefreshableCredentials.create_from_metadata(
        metadata=initial,
        refresh_using=_refresh_credentials,
        method="headroom-bedrock-refresh",
        # advisory_timeout = start a *background* refresh this many seconds
        # before expiry (non-blocking); mandatory_timeout = block to refresh
        # once inside this window. botocore requires advisory >= mandatory.
        advisory_timeout=EXPIRY_WINDOW_SECONDS,
        mandatory_timeout=max(60, EXPIRY_WINDOW_SECONDS // 2),
    )

    session = boto3.Session()
    # CRITICAL: set creds on the INNER botocore session. ``.client()`` resolves
    # creds via ``session._session.get_credentials()`` (botocore), NOT via the
    # boto3 wrapper. Setting ``session._credentials`` on the wrapper is a dead
    # write the signer never reads — the client then silently falls back to the
    # static env creds seeded at build time (expiry=None) and NEVER refreshes,
    # so the token dies at the first STS rollover and stays dead until a manual
    # restart. (This one-line bug looks healthy for the first ~1 h seed window.)
    session._session._credentials = creds

    return session.client("bedrock-runtime", region_name=region or AWS_REGION)

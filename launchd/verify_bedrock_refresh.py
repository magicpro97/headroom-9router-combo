#!/usr/bin/env python3
"""Self-check for bedrock_refresh.py — no AWS, no network, no real boto3.

Stubs boto3 + botocore so the hook's two load-bearing behaviours are proven:
  1. make_client wires RefreshableCredentials onto the INNER botocore session
     (session._session._credentials) — the dead-write bug that silently
     degrades the hook to "restart every hour".
  2. _refresh_credentials short-circuits on unchanged mtime + future expiry,
     and re-exports when the cached creds are expired.

Run:  python3 launchd/verify_bedrock_refresh.py    (exits non-zero on failure)
"""
import sys, types, os, importlib.util
from datetime import datetime, timezone, timedelta

# ---- stub boto3 + botocore.credentials before importing the hook ----------
captured = {}

class _FakeInnerSession:
    def __init__(self): self._credentials = None
class _FakeBoto3Session:
    def __init__(self): self._session = _FakeInnerSession()
    def client(self, name, region_name=None):
        captured["client_name"] = name
        captured["region"] = region_name
        captured["inner_creds"] = self._session._credentials
        return object()

class _FakeRefreshable:
    @classmethod
    def create_from_metadata(cls, metadata, refresh_using, method,
                             advisory_timeout=None, mandatory_timeout=None):
        inst = cls()
        inst.metadata = metadata
        inst.refresh_using = refresh_using
        return inst

boto3 = types.ModuleType("boto3"); boto3.Session = _FakeBoto3Session
botocore = types.ModuleType("botocore")
botocore_creds = types.ModuleType("botocore.credentials")
botocore_creds.RefreshableCredentials = _FakeRefreshable
botocore.credentials = botocore_creds
sys.modules["boto3"] = boto3
sys.modules["botocore"] = botocore
sys.modules["botocore.credentials"] = botocore_creds

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bedrock_refresh",
                                              os.path.join(HERE, "bedrock_refresh.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
fake_creds = {"access_key": "AKIA", "secret_key": "s", "token": "t",
              "expiry_time": future}

# ---- test 1: make_client wires creds onto the INNER session ---------------
mod._refresh_credentials = lambda: fake_creds          # bypass the AWS shell-out
mod.make_client("ap-northeast-1")
assert captured["client_name"] == "bedrock-runtime", captured
assert captured["region"] == "ap-northeast-1", captured
assert isinstance(captured["inner_creds"], _FakeRefreshable), \
    "DEAD-WRITE REGRESSION: creds not on session._session._credentials"
assert captured["inner_creds"].refresh_using is mod._refresh_credentials
print("PASS 1: refreshable creds wired to inner botocore session")

# ---- test 2: mtime+expiry cache short-circuits; expired re-exports --------
calls = {"n": 0}
def fake_export(future_exp):
    calls["n"] += 1
    return {"access_key": "AKIA", "secret_key": "s", "token": "t",
            "expiry_time": future_exp}

# reload a clean module so the real _refresh_credentials cache logic runs,
# but stub only the os/aws boundary it calls.
spec2 = importlib.util.spec_from_file_location("bedrock_refresh2",
                                               os.path.join(HERE, "bedrock_refresh.py"))
m2 = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(m2)

# Force the cached-creds path: seed module cache with a known mtime + future creds.
m2._LAST_MTIME = 1234.0
m2._LAST_CREDS = {"access_key": "A", "secret_key": "s", "token": "t",
                  "expiry_time": future}
m2.os.path.getmtime = lambda p: 1234.0     # unchanged mtime
got = m2._refresh_credentials()
assert got is m2._LAST_CREDS, "expected cache hit on unchanged mtime + future expiry"
print("PASS 2: cache hit on unchanged mtime + valid expiry (no shell-out)")

# Expired cached creds + unchanged mtime must NOT short-circuit. We stop it
# before the real aws shell-out by asserting it gets past the guard.
past = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
m2._LAST_CREDS = {"access_key": "A", "secret_key": "s", "token": "t",
                  "expiry_time": past}
m2.STS_REFRESH_CMD = None
m2.shutil.which = lambda x: None           # force RuntimeError right after the guard
try:
    m2._refresh_credentials()
    raise AssertionError("expected re-export path (RuntimeError on missing aws)")
except RuntimeError as e:
    assert "aws CLI is required" in str(e), e
print("PASS 3: expired cache forces re-export (no stale-cred short-circuit)")

print("\nALL CHECKS PASSED")

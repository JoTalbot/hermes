#!/usr/bin/env bash
set -euo pipefail

ACCOUNTS_CONFIG="${OCI_ACCOUNTS_CONFIG:-/etc/hermes/oci/accounts.yaml}"
OCI_BIN="${OCI_BIN:-oci}"

fail(){ echo "BLOCK: $*" >&2; exit 2; }
command -v "$OCI_BIN" >/dev/null 2>&1 || fail "OCI CLI not found: $OCI_BIN"
[ -r "$ACCOUNTS_CONFIG" ] || fail "accounts config not readable: $ACCOUNTS_CONFIG"

python3 - "$ACCOUNTS_CONFIG" <<'PY'
import sys, yaml
p=sys.argv[1]
with open(p, encoding="utf-8") as f:
    d=yaml.safe_load(f) or {}
if not isinstance(d, dict) or d.get("version") != 1:
    raise SystemExit("BLOCK: invalid accounts config version")
accounts=d.get("accounts") or []
if not accounts:
    raise SystemExit("BLOCK: no OCI accounts configured")
for a in accounts:
    for k in ("name","profile","tenancy_ocid","user_ocid","home_region"):
        if not a.get(k):
            raise SystemExit(f"BLOCK: account missing {k}")
    if not a.get("compartment_ocids"):
        raise SystemExit(f"BLOCK: account {a['name']} has no compartments")
    print(f"ACCOUNT {a['name']} profile={a['profile']} home_region={a['home_region']}")
PY

echo
echo "OCI identity check (read-only)"
python3 - "$ACCOUNTS_CONFIG" "$OCI_BIN" <<'PY'
import sys, subprocess, yaml
cfg, oci = sys.argv[1:]
d=yaml.safe_load(open(cfg, encoding="utf-8")) or {}
rc=0
for a in d.get("accounts", []):
    cmd=[oci,"iam","tenancy","get","--tenancy-id",a["tenancy_ocid"],"--profile",a["profile"],"--output","json"]
    try:
        p=subprocess.run(cmd, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
    except Exception as e:
        print(f"BLOCK {a['name']}: {type(e).__name__}")
        rc=1; continue
    if p.returncode:
        print(f"BLOCK {a['name']}: OCI authentication/authorization failed")
        rc=1
    else:
        print(f"OK    {a['name']}: authenticated")
raise SystemExit(rc)
PY

echo
echo "OCI bootstrap validation: PASS"

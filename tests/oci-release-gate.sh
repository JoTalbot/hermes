#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[OCI] release gate"
bash tests/oci-agent-selftest.sh
bash tests/oci-bootstrap-selftest.sh
bash tests/oci-execution-selftest.sh
bash tests/oci-execution-integration.sh
bash tests/oci-capacity-integration.sh

python3 - <<'PY'
from pathlib import Path
import re
p=Path("config/oci/execution-policy.example.yaml").read_text()
assert re.search(r"enabled:\s*false", p), "execution example must remain disabled"
assert re.search(r"allow_paid:\s*false", p), "paid resources must remain disabled"
print("OK  execution example is disabled and paid resources are blocked")
PY

echo "OCI-RELEASE-GATE: PASS"

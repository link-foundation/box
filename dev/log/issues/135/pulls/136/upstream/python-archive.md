## Problem

A Wayback API outage is reported as an unavailable snapshot. At `7a05d051`, the Python check returns the same result for a request exception and a valid empty `archived_snapshots` response. In both cases the CLI advises that it found no snapshot and tells authors to remove or replace the link. The broken link itself should still fail the check.

## Offline reproduction

Run from the template root with Python 3.11 or newer.

```bash
PYTHONPATH=scripts python3 - <<'PY'
from unittest.mock import patch
from check_web_archive import check_wayback_machine

url = "https://example.com/deleted"
with patch("check_web_archive.fetch_json", side_effect=TimeoutError("mock outage")):
    outage = check_wayback_machine(url)
with patch("check_web_archive.fetch_json", return_value={"archived_snapshots": {}}):
    missing = check_wayback_machine(url)
print(outage, missing)
assert outage == missing
PY
```

## Workaround and code fix

Keep Lychee's verdict and try a manual Wayback lookup after the API recovers before removing a historical reference. Make `ArchiveResult` distinguish available, missing, and unknown. Give request failures and invalid responses the unknown verdict and emit a separate notice without asserting that there is no snapshot. Test a snapshot, an empty result, a timeout, and invalid JSON with mocks. Keep the broken-link failure in all four cases.

Found in the audit for link-foundation/box#135. This concerns the recommendation printed by the archive helper. The workflow-level false success described in #54 is a separate issue.

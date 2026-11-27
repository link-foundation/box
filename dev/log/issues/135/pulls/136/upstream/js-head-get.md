Link recovery can mark a missing page healthy when HEAD returns 200 and GET returns 404. Lychee defaults to GET, so recovery needs the same HTTP method. This was found while comparing the reference templates for [Box issue #135](https://github.com/link-foundation/box/issues/135).

## Reproduce

In a checkout of this template, run the following from its root after replacing COMMAND with the recovery command listed below. This uses only a loopback server and no credentials.

```python
import os, pathlib, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()
    def do_GET(self):
        self.send_response(404)
        self.end_headers()

with HTTPServer(("127.0.0.1", 0), Handler) as server, tempfile.TemporaryDirectory() as tmp:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = pathlib.Path(tmp)
    report = root / "report.md"
    result = root / "output.txt"
    result.touch()
    report.write_text(
        "# Summary\n| Errors | 1 |\n| Timeouts | 0 |\n"
        "## Errors per input\n"
        f"* [503] <http://127.0.0.1:{server.server_port}/missing> | Rejected status code: 503\n"
    )
    subprocess.run(COMMAND, check=True, timeout=5, env=dict(
        os.environ, LYCHEE_OUTPUT=str(report), LYCHEE_EXIT_CODE="2",
        GITHUB_OUTPUT=str(result), RECOVERED_OUTPUT=str(root / "recovered.txt"),
        RECHECK_BUDGET_SECONDS="1", RECHECK_WAIT_MS="20",
    ))
    print(result.read_text())
```

Actual result is `all_recovered=true`. Expected result is for recovery to leave the report unresolved because GET returned 404.

## Workaround and suggested fix

For a workflow already affected, bypass recovery for these URLs and re-run Lychee with its default GET behavior. In the recovery helper, use GET for ordinary URLs, bound each request and the whole retry pass, and discard the body after checking headers. Leave fragment URLs to Lychee unless recovery also validates the body and fragment. Keep a fixture with different GET and HEAD statuses so the gate cannot regress.

Lychee documents its default under [the request method option](https://lychee.cli.rs/guides/cli/#-x---method).

Reproduced at `8e72538d579d904aff818c2447fb3c2413d3a989` with `COMMAND = ["node", "scripts/recheck-broken-links.mjs"]`.

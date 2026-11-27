#!/usr/bin/env python3
"""Run a checkout's link recovery against a localhost HEAD/GET disagreement."""

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import os
import subprocess
import tempfile
from threading import Thread


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    with HTTPServer(("127.0.0.1", 0), Handler) as server, tempfile.TemporaryDirectory() as work:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            root = Path(work)
            url = f"http://127.0.0.1:{server.server_port}/missing"
            report = root / "report.md"
            report.write_text(
                "# Summary\n| Errors | 1 |\n| Timeouts | 0 |\n"
                "## Errors per input\n"
                f"* [503] <{url}> | Rejected status code: 503\n"
            )
            outputs = root / "output.txt"
            outputs.touch()
            env = dict(
                os.environ,
                LYCHEE_OUTPUT=str(report),
                RECOVERED_OUTPUT=str(root / "recovered.txt"),
                GITHUB_OUTPUT=str(outputs),
                LYCHEE_EXIT_CODE="2",
                RECHECK_BUDGET_SECONDS="1",
                RECHECK_WAIT_MS="20",
            )
            subprocess.run(args.command, cwd=args.checkout, env=env, check=True, timeout=5)
            if "all_recovered=true" in outputs.read_text():
                print("FAIL: HEAD 200 concealed GET 404")
                return 1
            print("PASS: GET 404 kept the report unresolved")
            return 0
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    raise SystemExit(main())

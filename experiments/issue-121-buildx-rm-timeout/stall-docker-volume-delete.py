#!/usr/bin/env python3
"""Unix-socket proxy in front of the Docker socket that stalls one endpoint.

Every byte is forwarded unchanged, except that a chunk carrying
`DELETE /<api>/volumes/...` is held for DELAY seconds first. That is the only
difference from talking to dockerd directly, and it is the shape of the CI
failure this reproduces: the daemon is still unlinking a large BuildKit state
volume when buildx stops waiting.

Chunk-level rather than request-level on purpose: the Docker client reuses one
keep-alive connection for many requests, so a proxy that only inspects the
first request line of a connection never sees the delete at all.
"""
import os
import socket
import socketserver
import threading
import time

UPSTREAM = os.environ.get("UPSTREAM_SOCK", "/var/run/docker.sock")
LISTEN = os.environ["LISTEN_SOCK"]
DELAY = float(os.environ.get("DELAY_SECONDS", "25"))


def pump(src, dst, stall):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if stall and b"DELETE /" in data and b"/volumes/" in data:
                line = data.split(b"\r\n", 1)[0].decode(errors="replace")
                print(f"[proxy] stalling {line} for {DELAY}s", flush=True)
                time.sleep(DELAY)
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        up.connect(UPSTREAM)
        t = threading.Thread(target=pump, args=(up, self.request, False), daemon=True)
        t.start()
        pump(self.request, up, True)


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


if os.path.exists(LISTEN):
    os.unlink(LISTEN)
srv = Server(LISTEN, Handler)
os.chmod(LISTEN, 0o666)
print(f"[proxy] listening on {LISTEN} -> {UPSTREAM}, DELAY={DELAY}s", flush=True)
srv.serve_forever()

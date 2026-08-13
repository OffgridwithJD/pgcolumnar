#!/usr/bin/env python3
# Range-capable logging HTTP fixture for test/objstore_http_read.sh (#393 M1).
#
# Serves files from --dir and appends one line per request to --log:
#     METHOD <path> <value of the Range header, or "-">
# The log is the suite's seam B: request counts are asserted against it, so this
# server must log every request exactly once, before serving it.
#
# Special path prefixes, used by the failure and cancel arms:
#   /norange/<file>  serve <file> but IGNORE any Range header (status 200, whole
#                    body): the client must treat this as an error, never as data.
#   /stall/<file>    answer the first ranged GET's headers, send half the body,
#                    then sleep: the cancel arm proves statement_timeout gets the
#                    backend back while the transfer is wedged.
#
# Written fresh for pgColumnar.

import argparse
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):   # silence stderr chatter
        pass

    def _log_line(self):
        rng = self.headers.get("Range", "-").replace(" ", "")
        with open(self.server.reqlog, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, rng))

    def _resolve(self):
        path = self.path
        mode = "normal"
        for prefix in ("/norange/", "/stall/"):
            if path.startswith(prefix):
                mode = prefix.strip("/")
                path = "/" + path[len(prefix):]
                break
        local = os.path.join(self.server.rootdir, path.lstrip("/"))
        return mode, local

    def _head_common(self, local):
        if not os.path.isfile(local):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return -1
        return os.path.getsize(local)

    def do_HEAD(self):
        self._log_line()
        size = self._head_common(self._resolve()[1])
        if size < 0:
            return
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def do_GET(self):
        self._log_line()
        mode, local = self._resolve()
        size = self._head_common(local)
        if size < 0:
            return

        rng = self.headers.get("Range")
        m = RANGE_RE.match(rng.replace(" ", "")) if rng else None
        if m is None or mode == "norange":
            # No Range, or deliberately ignoring it: whole object, status 200.
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(local, "rb") as f:
                self.wfile.write(f.read())
            return

        if m.group(1) == "":                     # suffix form bytes=-N
            n = int(m.group(2))
            lo, hi = max(0, size - n), size - 1
        else:
            lo = int(m.group(1))
            hi = int(m.group(2)) if m.group(2) != "" else size - 1
        hi = min(hi, size - 1)
        if lo > hi or lo >= size:
            self.send_response(416)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        n = hi - lo + 1
        with open(local, "rb") as f:
            f.seek(lo)
            body = f.read(n)
        self.send_response(206)
        self.send_header("Content-Range", "bytes %d-%d/%d" % (lo, hi, size))
        self.send_header("Content-Length", str(n))
        self.end_headers()
        if mode == "stall":
            self.wfile.write(body[: n // 2])
            self.wfile.flush()
            time.sleep(300)                      # the suite cancels long before
            return
        self.wfile.write(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.rootdir = args.dir
    srv.reqlog = args.log
    open(args.log, "a").close()
    # Readiness marker for the suite: print once the socket is bound.
    print("READY", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())

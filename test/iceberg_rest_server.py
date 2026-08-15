#!/usr/bin/env python3
# Hermetic Apache Iceberg REST Catalog fixture, for test/iceberg_rest.sh
# (#388 phase 7). It answers the read-only subset the pgColumnar REST client
# speaks -- GET /v1/config, loadTable, and listing -- and it VERIFIES the
# Authorization: Bearer header, so a green read proves the C client and an
# independent server agree on the request the same way the SigV4 fixture proves
# the signer. No third-party catalog, no container: the suite runs in CI.
#
# It never logs the token value (only whether an Authorization header was
# present), so the suite can assert both "the token was sent" (the server would
# 401 otherwise) and "the token never appears in any log".
#
# Endpoints:
#   GET /v1/config[?warehouse=...]                 -> {"defaults":{},"overrides":{...}}
#   GET /v1/namespaces                             -> {"namespaces":[["db"],...]}
#   GET /v1/namespaces/{ns}/tables                 -> {"identifiers":[...]}
#   GET /v1/namespaces/{ns}/tables/{table}         -> loadTable {metadata-location,...}
# with an optional {prefix} segment after /v1/ when --prefix is given, exactly
# as a real catalog splices the config-returned prefix.
#
# Special table names drive the failure arms:
#   toobig   loadTable answers 200 with a huge Content-Length and no body, so a
#            client honoring a response cap refuses before reading it.
#
# Written fresh for pgColumnar. Reuses no upstream test harness.

import argparse
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):     # silence stderr chatter
        pass

    # ---- helpers ----------------------------------------------------------
    def _logline(self, verb, path):
        # AUTH=yes/no ONLY -- never the token value.
        has_auth = "yes" if self.headers.get("Authorization") else "no"
        with open(ARGS.log, "a") as fh:
            fh.write("%s %s AUTH=%s\n" % (verb, path, has_auth))

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        # When --token is set, every resource requires exactly "Bearer <token>".
        if not ARGS.token:
            return True
        got = self.headers.get("Authorization", "")
        return got == ("Bearer " + ARGS.token)

    def _unauthorized(self):
        self._send_json(401, {"error": {"message": "not authorized",
                                        "type": "NotAuthorizedException",
                                        "code": 401}})

    def _not_found(self, msg):
        self._send_json(404, {"error": {"message": msg,
                                        "type": "NoSuchTableException",
                                        "code": 404}})

    def _strip_prefix(self, rest):
        # rest is the path after "/v1/". Consume the optional {prefix} segment.
        if ARGS.prefix:
            want = ARGS.prefix.strip("/") + "/"
            if not rest.startswith(want):
                return None
            rest = rest[len(want):]
        return rest

    # ---- routing ----------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        self._logline("GET", path)

        if not path.startswith("/v1/"):
            self._not_found("no such path")
            return
        if not self._auth_ok():
            self._unauthorized()
            return

        # /v1/config is not under the prefix (the client calls it to LEARN the
        # prefix), so handle it before stripping.
        if path == "/v1/config":
            if ARGS.bad_config:
                # a hostile/broken catalog: config is not a JSON object. The
                # client must refuse this, not walk it as key/value pairs.
                self._send_json(200, [])
                return
            overrides = {}
            if ARGS.prefix:
                overrides["prefix"] = ARGS.prefix.strip("/")
            self._send_json(200, {"defaults": {}, "overrides": overrides})
            return

        rest = self._strip_prefix(path[len("/v1/"):])
        if rest is None:
            self._not_found("bad prefix")
            return

        if rest == "namespaces":
            self._send_json(200, {"namespaces": [["db"]]})
            return

        parts = rest.split("/")
        # namespaces/{ns}/tables  and  namespaces/{ns}/tables/{table}
        if len(parts) >= 3 and parts[0] == "namespaces" and parts[2] == "tables":
            ns = urllib.parse.unquote(parts[1])
            if len(parts) == 3:
                self._send_json(200, {"identifiers": [
                    {"namespace": [ns], "name": "events"}]})
                return
            table = urllib.parse.unquote(parts[3])
            self._load_table(ns, table)
            return

        self._not_found("no such resource")

    def _load_table(self, ns, table):
        if table == "toobig":
            # advertise a body far larger than any sane response cap, send none:
            # a client honoring the cap must refuse on the advertised length.
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "100000000")
            self.end_headers()
            return
        # the namespace wire form joins multi-level parts with 0x1F; accept both
        # a single "db" and the unit-separated form.
        ns_norm = ns.replace("\x1f", ".")
        if ns_norm != ARGS.namespace or table != ARGS.table:
            self._not_found("no such table %s.%s" % (ns, table))
            return
        self._send_json(200, {
            "metadata-location": ARGS.metadata_location,
            "metadata": {"format-version": 2, "location": ARGS.table_location},
            "config": {},
        })


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--token", default="")
    ap.add_argument("--prefix", default="")
    ap.add_argument("--namespace", default="db")
    ap.add_argument("--table", default="events")
    ap.add_argument("--metadata-location", required=True)
    ap.add_argument("--table-location", default="")
    ap.add_argument("--bad-config", action="store_true")
    ARGS = ap.parse_args()
    open(ARGS.log, "w").close()
    httpd = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print("READY", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()

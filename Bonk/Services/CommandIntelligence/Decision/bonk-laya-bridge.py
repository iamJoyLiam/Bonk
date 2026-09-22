#!/usr/bin/env python3
"""bonk-laya-bridge.py — reference sidecar exposing a local Laya service
to Bonk over HTTP. Requires: pip install laya (plus torch/transformers).

  python3 bonk-laya-bridge.py [--port 8765] [--preload english,multilingual]

Contract (mirrors TypeSafe SystemOne shapes):
  POST /v1/decide  {"state": str|obj, "questions": {...}, "checkpoint": ""}
      -> {"answers": {...}}  (verbatim result of Router().predict)
  GET  /v1/health -> 200 {"ok": true} once a checkpoint is loaded.

In Bonk Settings → Decision Engine → Laya, point the endpoint at
http://127.0.0.1:8765. Empty checkpoint lets Laya's Router pick per request.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from laya import Router

router: Router | None = None


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/v1/health":
            self._send(200 if router is not None else 503, {"ok": router is not None})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/decide" or router is None:
            self._send(404 if router is not None else 503, {"error": "not ready"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length) or b"{}")
            kwargs = {}
            if req.get("checkpoint"):
                kwargs["model"] = req["checkpoint"]
            result = router.predict(req.get("state", ""), req.get("questions", {}), **kwargs)
            self._send(200, {"answers": result.get("answers", {})})
        except Exception as e:  # noqa: BLE001 — report bridge errors as JSON
            self._send(500, {"error": str(e)})

    def log_message(self, *args: object) -> None:
        pass


def main() -> None:
    global router
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--preload", default="english,multilingual")
    args = parser.parse_args()
    router = Router(preload=True)
    router.preload([c.strip() for c in args.preload.split(",") if c.strip()])
    print(f"bonk-laya-bridge on 127.0.0.1:{args.port}")
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

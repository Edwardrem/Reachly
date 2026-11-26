#!/usr/bin/env python3
"""orders-api: the shop's order service. nginx proxies /api/ here."""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ORDERS = "/var/lib/shop/orders"
LOG = "/var/log/shop/orders-api.log"


def log(line):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "orders-api/2.3.1"

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/api/v1/products"):
            self.reply(200, {"items": [{"id": 1042, "name": "Trail runner", "price": 89.0}], "page": 1})
        elif self.path.startswith("/api/v1/cart"):
            self.reply(200, {"items": [], "total": 0})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = self.rfile.read(length) if length else b"{}"
        if self.path.startswith("/api/v1/checkout"):
            order = "ord_" + uuid.uuid4().hex[:12]
            try:
                with open(os.path.join(ORDERS, order + ".json"), "wb") as f:
                    f.write(payload)
                    f.flush()
                    os.fsync(f.fileno())
            except OSError as error:
                log(f"ERROR checkout {order}: could not save order: {error}")
                self.reply(500, {"error": "could not save order, please try again"})
                return
            log(f"INFO checkout {order} saved")
            self.reply(201, {"order": order, "status": "confirmed"})
        elif self.path.startswith("/api/v1/cart"):
            self.reply(201, {"ok": True})
        else:
            self.reply(404, {"error": "not found"})

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()

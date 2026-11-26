"""Writes realistic nginx and shop logs for web-01 into the folder given (default: .state/logs next to this file).

The story: 15 days ago a load-balancer health check was reconfigured to hit /healthz three times a second, and the
same day logrotate stopped running (its timer is off). access.log has grown since; when web-01 starts, its
entrypoint copies it into the small /var volume until the disk is full, the way a real full disk cuts a log mid-line.
Times are relative to now, so run it again before each start: the disk filled 50 minutes ago.

Usage: python3 gen_logs.py [output folder]
"""
import datetime as dt
import gzip
import os
import random
import sys

random.seed(26)
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".state", "logs")
os.makedirs(out, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
start = now - dt.timedelta(days=15, hours=2)

paths = [
    ("GET", "/", 200, 5321), ("GET", "/static/app.3f9c1.js", 200, 182044), ("GET", "/static/app.3f9c1.css", 200, 40912),
    ("GET", "/api/v1/products?page=1", 200, 8123), ("GET", "/api/v1/products?page=2", 200, 7911),
    ("GET", "/api/v1/products/1042", 200, 2204), ("GET", "/api/v1/cart", 200, 912), ("POST", "/api/v1/cart/items", 201, 418),
    ("POST", "/api/v1/checkout", 200, 1290), ("GET", "/api/v1/orders/latest", 200, 1544), ("GET", "/favicon.ico", 304, 0),
    ("GET", "/wp-login.php", 404, 153), ("GET", "/api/v1/search?q=shoes", 200, 6655),
]
weights = [14, 10, 10, 12, 6, 9, 8, 4, 3, 3, 6, 1, 5]
agents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (Linux; Android 15; SM-A556E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Mobile Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
]
# Customer addresses come from the documentation ranges (RFC 5737), so none of them is anyone real.
nets = ("192.0.2", "198.51.100", "203.0.113")
clients = [f"{nets[i % len(nets)]}.{random.randint(1, 254)}" for i in range(200)]


def stamp(t):
    return t.strftime("%d/%b/%Y:%H:%M:%S +0000")


def write_access(path, t0, t1, healthz_per_second):
    with open(path, "w") as f:
        t = t0
        step = dt.timedelta(seconds=1)
        while t < t1:
            s = stamp(t)
            for _ in range(healthz_per_second):
                f.write(f'10.0.0.2 - - [{s}] "GET /healthz HTTP/1.1" 200 2 "-" "lb-healthcheck/2.4"\n')
            # Shop traffic: busier by day (UTC+2), quiet at night.
            hour = (t.hour + 2) % 24
            rate = 0.55 if 8 <= hour <= 21 else 0.08
            while random.random() < rate:
                method, p, code, size = random.choices(paths, weights)[0]
                if p == "/api/v1/checkout" and random.random() < 0.01:
                    code, size = 502, 157
                f.write(f'{random.choice(clients)} - - [{s}] "{method} {p} HTTP/1.1" {code} {size} '
                        f'"https://shop.example.org/" "{random.choice(agents)}"\n')
                rate *= 0.5
            t += step


rotated = start - dt.timedelta(days=1)
# Yesterday's rotation (16 days ago), back when health checks ran once every 10 seconds, and older ones compressed.
write_access(os.path.join(out, "access.log.1"), rotated, start, 0)
for n in (2, 3):
    tmp = os.path.join(out, f"access.log.{n}")
    write_access(tmp, rotated - dt.timedelta(days=n - 1), rotated - dt.timedelta(days=n - 2), 0)
    with open(tmp, "rb") as src, gzip.open(tmp + ".gz", "wb") as dst:
        dst.write(src.read())
    os.remove(tmp)
write_access(os.path.join(out, "access.log"), start, now - dt.timedelta(minutes=50), 3)

# error.log: the odd upstream timeout over two weeks, then the disk fills. Only the lines that fit in the log's last
# free block were written (about 4 KB), a few seconds' worth of health checks, then nothing more.
full = now - dt.timedelta(minutes=50)
with open(os.path.join(out, "error.log"), "w") as f:
    t = start
    while True:
        t += dt.timedelta(hours=random.uniform(5, 30))
        if t >= full - dt.timedelta(minutes=5):
            break
        f.write(f'{t:%Y/%m/%d %H:%M:%S} [error] 29#29: *{random.randint(10000, 99999)} upstream timed out (110: Connection timed out) '
                f'while reading response header from upstream, client: {random.choice(clients)}, server: shop.example.org, '
                f'request: "GET /api/v1/products?page=2 HTTP/1.1", upstream: "http://127.0.0.1:8080/api/v1/products?page=2", host: "shop.example.org"\n')
    t = full
    conn = 4821190
    for _ in range(14):
        conn += random.randint(1, 3)
        f.write(f'{t:%Y/%m/%d %H:%M:%S} [alert] 29#29: *{conn} write() to "/var/log/nginx/access.log" failed '
                f'(28: No space left on device) while logging request, client: 10.0.0.2, server: shop.example.org, '
                f'request: "GET /healthz HTTP/1.1", host: "10.0.1.11"\n')
        t += dt.timedelta(seconds=random.uniform(0.25, 0.4))

# orders-api.log: every saved order, then the first failures after the disk filled (only ~4 KB of them fit).
orders = []
with open(os.path.join(out, "orders-api.log"), "w") as f:
    t = start
    while t < full:
        hour = (t.hour + 2) % 24
        t += dt.timedelta(seconds=random.expovariate(1 / (240 if 8 <= hour <= 21 else 1500)))
        if t >= full:
            break
        order = "ord_" + "".join(random.choices("0123456789abcdef", k=12))
        orders.append((order, t))
        f.write(f"{t:%Y-%m-%d %H:%M:%S} INFO checkout {order} saved\n")
    t = full + dt.timedelta(seconds=40)
    for _ in range(24):
        order = "ord_" + "".join(random.choices("0123456789abcdef", k=12))
        f.write(f"{t:%Y-%m-%d %H:%M:%S} ERROR checkout {order}: could not save order: [Errno 28] No space left on device: "
                f"'/var/lib/shop/orders/{order}.json'\n")
        t += dt.timedelta(seconds=random.expovariate(1 / 90))
with open(os.path.join(out, "orders.txt"), "w") as f:
    for order, t in orders[-400:]:
        f.write(f"{order} {int(t.timestamp())}\n")

# logrotate's own record: the last run was 15 days ago.
with open(os.path.join(out, "logrotate.status"), "w") as f:
    f.write('logrotate state -- version 2\n')
    f.write(f'"/var/log/nginx/*.log" {start:%Y-%-m-%-d-%-H:0:0}\n')
    f.write(f'"/var/log/apt/term.log" {start:%Y-%-m-%-d-%-H:0:0}\n')
    f.write(f'"/var/log/shop/*.log" {start:%Y-%-m-%-d-%-H:0:0}\n')
for name in sorted(os.listdir(out)):
    print(name, os.path.getsize(os.path.join(out, name)) // 1_000_000, "MB")

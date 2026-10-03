#!/usr/bin/env python3
"""Large-input fixture for the zash stress benchmark.

usage: gen.py DEST
env:   STRESS_MB=200   size of logs/big.log
Never commit the generated tree.
"""
import os, random, sys

dest = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
mb = int(os.environ.get("STRESS_MB", "200"))
marker = os.path.join(dest, ".stress-ok")
if os.path.exists(marker) and open(marker).read().strip() == str(mb):
    print("stress fixture up to date:", dest); sys.exit(0)
os.makedirs(os.path.join(dest, "logs"), exist_ok=True)
rng = random.Random(1234)
NOUNS = "config request response user session token cache buffer queue worker route header payload record schema index stream event task job node graph".split()
LEVELS = ["INFO"] * 80 + ["WARN"] * 12 + ["ERROR"] * 6 + ["DEBUG"] * 2
out = []
for i in range(100000):
    lvl = rng.choice(LEVELS)
    msg = {"INFO": "request ok", "WARN": "slow upstream", "ERROR": rng.choice(["connection refused", "timeout waiting for lock", "unexpected EOF", "disk quota exceeded"]), "DEBUG": "cache miss"}[lvl]
    out.append("2025-03-14T%02d:%02d:%02dZ %-5s worker-%d %s id=%d path=/api/v1/%ss status=%d dur=%dms\n" % (
        (i // 3600) % 24, (i // 60) % 60, i % 60, lvl, rng.randint(0, 15), msg, rng.randint(1000, 999999), rng.choice(NOUNS),
        rng.choice([200] * 9 + [500, 404]), rng.randint(1, 900)))
pool = "".join(out).encode()
size = mb << 20
n = 0
with open(os.path.join(dest, "logs", "big.log"), "wb") as f:
    while n < size:
        chunk = pool if size - n >= len(pool) else pool[: size - n]
        f.write(chunk); n += len(chunk)
    if not chunk.endswith(b"\n"): f.write(b"\n")
open(marker, "w").write(str(mb))
print("stress fixture built:", dest)

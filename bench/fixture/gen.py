#!/usr/bin/env python3
"""Deterministic fixture tree for the zash benchmark corpus.

usage: gen.py DEST [--force]
env:   FIXTURE_BIG=50m,500m   also create logs/medium.log (50MB) / logs/huge.log (500MB)
       FIXTURE_SEED=1234
Never commit the generated tree.
"""
import os, random, subprocess, sys, shutil

dest = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
force = "--force" in sys.argv
SEED = int(os.environ.get("FIXTURE_SEED", "1234"))
BIG = [x for x in os.environ.get("FIXTURE_BIG", "").lower().split(",") if x]
STAMP = 1700000000
rng = random.Random(SEED)

if os.path.exists(os.path.join(dest, ".git", "fixture-ok")):
    have = open(os.path.join(dest, ".git", "fixture-ok")).read().split()
    want = [str(SEED)] + sorted(BIG)
    if not force and have[:1] == want[:1] and set(want[1:]) <= set(have[1:]):
        print("fixture up to date:", dest); sys.exit(0)
if os.path.exists(dest):
    shutil.rmtree(dest)
os.makedirs(dest)

VERBS = "get set parse load save handle build render fetch update delete create validate resolve dispatch encode decode flush merge split scan emit".split()
NOUNS = "config request response user session token cache buffer queue worker route header payload record schema index stream event task job node graph".split()
COMMENTS = ["TODO: tighten this up", "FIXME: handle empty input", "NOTE: called from hot path", "HACK: workaround for upstream bug", "XXX: revisit", "TODO(lee): add tests"]
LEVELS = ["INFO"] * 80 + ["WARN"] * 12 + ["ERROR"] * 6 + ["DEBUG"] * 2

def fname():
    return rng.choice(VERBS) + "_" + rng.choice(NOUNS)
def camel(s):
    return "".join(p.capitalize() if i else p for i, p in enumerate(s.split("_")))
def pascal(s):
    return "".join(p.capitalize() for p in s.split("_"))

def body_lines(style, n):
    out = []
    for i in range(n):
        f = fname()
        r = rng.random()
        c = ""
        if r < 0.08: c = rng.choice(COMMENTS)
        out.append((f, c, i))
    return out

def gen_go(pkg, idx):
    L = [f"package {pkg}", "", 'import (', '\t"fmt"', '\t"strings"', ')', ""]
    for f, c, i in body_lines("go", rng.randint(3, 12)):
        L.append(f"func {pascal(f)}(x int) (int, error) {{")
        if c: L.append(f"\t// {c}")
        L.append(f"\tif x < {rng.randint(0,99)} {{")
        L.append(f'\t\treturn 0, fmt.Errorf("{f}: bad input %d", x)')
        L.append("\t}")
        L.append(f"\treturn x * {rng.randint(2,9)}, nil")
        L.append("}"); L.append("")
    return L

def gen_py(pkg, idx):
    L = ["import os", "import sys", "import json", "", ""]
    for f, c, i in body_lines("py", rng.randint(3, 12)):
        L.append(f"def {f}(x, y={rng.randint(0,9)}):")
        if c: L.append(f"    # {c}")
        L.append(f"    if x is None:")
        L.append(f"        raise ValueError('{f} failed')")
        L.append(f"    return x + y * {rng.randint(1,9)}")
        L.append(""); L.append("")
    if rng.random() < 0.3:
        L.append(f"class {pascal(fname())}:")
        L.append("    def __init__(self):\n        self.items = []\n")
    return L

def gen_js(pkg, idx):
    L = ["'use strict';", "const fs = require('fs');", ""]
    for f, c, i in body_lines("js", rng.randint(3, 10)):
        L.append(f"function {camel(f)}(arg) {{")
        if c: L.append(f"  // {c}")
        L.append(f"  if (!arg) throw new Error('{f}: missing arg');")
        L.append(f"  return arg.length * {rng.randint(1,9)};")
        L.append("}"); L.append("")
    L.append("module.exports = { " + ", ".join(camel(fname()) for _ in range(2)) + " };")
    return L

def gen_ts(pkg, idx):
    L = ["import { Logger } from './logger';", "", f"export interface {pascal(fname())} {{ id: number; name: string }}", ""]
    for f, c, i in body_lines("ts", rng.randint(3, 10)):
        L.append(f"export async function {camel(f)}(arg: string): Promise<number> {{")
        if c: L.append(f"  // {c}")
        L.append(f"  if (arg === '') throw new Error('{f} empty');")
        L.append(f"  return arg.length + {rng.randint(1,99)};")
        L.append("}"); L.append("")
    return L

def gen_rs(pkg, idx):
    L = ["use std::collections::HashMap;", ""]
    for f, c, i in body_lines("rs", rng.randint(3, 10)):
        L.append(f"pub fn {f}(x: u32) -> Result<u32, String> {{")
        if c: L.append(f"    // {c}")
        L.append(f"    if x > {rng.randint(10,999)} {{ return Err(\"{f} overflow\".to_string()); }}")
        L.append(f"    Ok(x * {rng.randint(2,9)})")
        L.append("}"); L.append("")
    return L

def gen_c(pkg, idx):
    L = ["#include <stdio.h>", "#include <stdlib.h>", ""]
    for f, c, i in body_lines("c", rng.randint(3, 10)):
        L.append(f"int {f}(int x) {{")
        if c: L.append(f"    /* {c} */")
        L.append(f"    if (x < {rng.randint(0,50)}) return -1;")
        L.append(f"    return x * {rng.randint(2,9)};")
        L.append("}"); L.append("")
    return L

def gen_h(pkg, idx):
    L = [f"#ifndef {pkg.upper()}_{idx}_H", f"#define {pkg.upper()}_{idx}_H", ""]
    for _ in range(rng.randint(2, 6)): L.append(f"int {fname()}(int x);")
    L += ["", "#endif"]
    return L

def gen_java(pkg, idx):
    cls = f"F{idx:04d}"
    L = [f"package com.example.{pkg};", "", "import java.util.List;", "", f"public class {cls} {{"]
    for f, c, i in body_lines("java", rng.randint(2, 8)):
        L.append(f"    public int {camel(f)}(int x) {{")
        if c: L.append(f"        // {c}")
        L.append(f"        if (x < 0) throw new IllegalArgumentException(\"{f}\");")
        L.append(f"        return x * {rng.randint(2,9)};")
        L.append("    }"); L.append("")
    L.append("}")
    return L

def gen_sh(pkg, idx):
    L = ["#!/usr/bin/env bash", "set -euo pipefail", ""]
    for f, c, i in body_lines("sh", rng.randint(2, 6)):
        L.append(f"{f}() {{")
        if c: L.append(f"  # {c}")
        L.append(f'  echo "{f} $1"')
        L.append("}"); L.append("")
    return L

def gen_md(pkg, idx):
    L = [f"# {pascal(fname())} guide {idx}", ""]
    for _ in range(rng.randint(3, 14)):
        L.append(f"Use `{fname()}` to {rng.choice(VERBS)} the {rng.choice(NOUNS)}. See also section {rng.randint(1,9)}.")
        if rng.random() < 0.1: L.append(rng.choice(COMMENTS))
        L.append("")
    return L

def gen_json(pkg, idx):
    items = ",\n".join(f'  "{fname()}": {rng.randint(0,9999)}' for _ in range(rng.randint(3, 12)))
    return ["{", items, "}"]

def gen_yaml(pkg, idx):
    return [f"{fname()}: {rng.randint(0,99)}" if i % 3 else f"{fname()}:\n  enabled: {rng.choice(['true','false'])}\n  retries: {rng.randint(0,5)}" for i in range(rng.randint(4, 20))]

def gen_test_py(pkg, idx):
    L = ["import unittest", "", f"class Test{idx}(unittest.TestCase):"]
    for f, c, i in body_lines("py", rng.randint(2, 8)):
        L.append(f"    def test_{f}(self):")
        L.append(f"        self.assertEqual(1 + 1, 2)")
        if c: L.append(f"        # {c}")
    return L

def write(path, lines):
    full = os.path.join(dest, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write("\n".join(lines) + "\n")

def tree(prefix, ndirs, nfiles, ext, gen, dname="pkg", sub=""):
    n = 0
    for d in range(ndirs):
        pkg = f"{dname}{d:02d}"
        for i in range(nfiles):
            write(f"{prefix}/{pkg}/{sub}f{n:04d}.{ext}", gen(pkg, n)); n += 1

tree("src/go", 24, 25, "go", gen_go, "pkg")
tree("src/py", 20, 30, "py", gen_py, "mod")
tree("src/js", 20, 20, "js", gen_js, "comp")
tree("src/ts", 20, 20, "ts", gen_ts, "svc")
tree("src/rs", 15, 20, "rs", gen_rs, "crate", "src/")
tree("src/c", 10, 20, "c", gen_c, "lib")
tree("src/c", 10, 10, "h", lambda p, i: gen_h(p, i + 1000), "lib")
tree("src/java/com/example", 10, 10, "java", gen_java, "pkg")
tree("tests", 1, 100, "py", gen_test_py, "unit")
tree("scripts", 1, 50, "sh", gen_sh, "tools")
tree("docs", 1, 100, "md", gen_md, "guide")
tree("config", 1, 80, "json", gen_json, "cfg")
tree("config", 1, 40, "yaml", gen_yaml, "env")
for name, body in {
    "README.md": ["# fixture repo", "", "Synthetic repository for zash benchmarks.", "TODO: write docs"],
    "Makefile": ["all:", "\t@echo build", "", "test:", "\t@echo test"],
    "package.json": ['{', '  "name": "fixture",', '  "version": "1.0.0",', '  "scripts": { "test": "echo ok" }', '}'],
    "go.mod": ["module example.com/fixture", "", "go 1.22"],
    "Cargo.toml": ["[package]", 'name = "fixture"', 'version = "0.1.0"'],
    ".gitignore": ["node_modules/", "target/", "dist/", "build/", "*.log", "logs/", ".scratch/"],
}.items():
    write(name, body)

for i in range(1500):
    p = f"node_modules/pkg{i // 10:03d}/"
    j = i % 10
    if j == 0: write(p + "package.json", ['{ "name": "pkg%03d", "version": "1.%d.0" }' % (i // 10, i % 7)])
    write(p + f"lib/m{j}.js", gen_js("nm", i))
for i in range(60):
    write(f"build/out{i:03d}.o", [f"obj {i}"] * 20)

words_pool = [fname() + str(rng.randint(0, 99)) for _ in range(2000)]
write("data/words.txt", [rng.choice(words_pool) for _ in range(20000)])
write("data/numbers.txt", [str(rng.randint(-5000, 99999)) for _ in range(10000)])
write("data/spaces.txt", ["  ".join([rng.choice(words_pool) for _ in range(rng.randint(2, 8))]) + "   " + str(i) for i in range(5000)])
write("data/users.csv", ["id,name,email,age,country"] + [f"{i},{rng.choice(NOUNS)}{i},u{i}@example.com,{rng.randint(18,80)},{rng.choice(['US','DE','FR','JP','BR','IN','GB'])}" for i in range(10000)])
write("data/users.tsv", ["id\tname\tscore\tteam"] + [f"{i}\t{rng.choice(VERBS)}{i}\t{rng.randint(0,1000)}\t{rng.choice(['red','blue','green','gold'])}" for i in range(8000)])
write("data/kv.env", [f"{fname().upper()}_{i}={rng.randint(0,9999)}" for i in range(200)])
write("data/paths.txt", [f"/srv/app/{rng.choice(NOUNS)}/{rng.choice(VERBS)}/{rng.choice(NOUNS)}{rng.randint(0,40)}.{rng.choice(['go','py','js','ts'])}" for i in range(5000)])
for i in range(60):
    write(f"data/small/s{i:02d}.txt", [f"{fname()} {rng.randint(0,99)}" for _ in range(rng.randint(1, 40))])
write("data/empty.txt", [])
open(os.path.join(dest, "data/empty.txt"), "w").close()
write("data/oneline.txt", ["hello world"])

def access_line(i):
    return '10.%d.%d.%d - - [14/Mar/2025:12:%02d:%02d +0000] "%s /api/v1/%s HTTP/1.1" %d %d' % (
        rng.randint(0, 9), rng.randint(0, 255), rng.randint(1, 254), (i // 60) % 60, i % 60,
        rng.choice(["GET"] * 8 + ["POST"] * 2 + ["PUT"]), rng.choice(NOUNS) + "s", rng.choice([200] * 12 + [404, 500, 301, 403]), rng.randint(100, 90000))
write("data/access.log", [access_line(i) for i in range(20000)])

def log_pool(n):
    out = []
    for i in range(n):
        lvl = rng.choice(LEVELS)
        msg = {"INFO": "request ok", "WARN": "slow upstream", "ERROR": rng.choice(["connection refused", "timeout waiting for lock", "unexpected EOF", "disk quota exceeded"]), "DEBUG": "cache miss"}[lvl]
        out.append("2025-03-14T%02d:%02d:%02dZ %-5s worker-%d %s id=%d path=/api/v1/%ss status=%d dur=%dms\n" % (
            (i // 3600) % 24, (i // 60) % 60, i % 60, lvl, rng.randint(0, 15), msg, rng.randint(1000, 999999), rng.choice(NOUNS),
            rng.choice([200] * 9 + [500, 404]), rng.randint(1, 900)))
    return "".join(out).encode()

os.makedirs(os.path.join(dest, "logs"), exist_ok=True)
pool = log_pool(100000)
def write_big(name, size):
    with open(os.path.join(dest, "logs", name), "wb") as f:
        n = 0
        while n < size:
            chunk = pool[: size - n] if size - n < len(pool) else pool
            f.write(chunk); n += len(chunk)
        if not chunk.endswith(b"\n"): f.write(b"\n")
write_big("app.log", 1 << 20)
for b in BIG:
    if b == "50m": write_big("medium.log", 50 << 20)
    elif b == "500m": write_big("huge.log", 500 << 20)
    elif b == "1m": pass
    else: sys.exit("bad FIXTURE_BIG entry " + b)

genv = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null", GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.com",
            GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.com")
def git(*a, date=None):
    e = dict(genv)
    if date: e["GIT_AUTHOR_DATE"] = e["GIT_COMMITTER_DATE"] = date
    subprocess.run(["git", "-C", dest, *a], check=True, env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

git("init", "-q", "-b", "main")
git("config", "core.fsmonitor", "false"); git("config", "gc.auto", "0")
groups = [("go", ["src/go"]), ("py", ["src/py", "tests"]), ("js/ts", ["src/js", "src/ts"]), ("rust and c", ["src/rs", "src/c"]),
          ("java and scripts", ["src/java", "scripts"]), ("docs", ["docs", "README.md"]), ("config", ["config", "data"]), ("build files", ["Makefile", "package.json", "go.mod", "Cargo.toml", ".gitignore"])]
for gi, (msg, paths) in enumerate(groups):
    git("add", "--", *paths)
    git("commit", "-q", "-m", f"Add {msg}", date=f"{STAMP + gi * 86400} +0000")
    if gi == 2: git("tag", "v0.1.0")
    if gi == 4: git("branch", "feature/x")
for k in range(5):
    for j in range(40):
        p = os.path.join(dest, f"src/go/pkg{k:02d}/f{k * 25 + j % 25:04d}.go")
        with open(p, "a") as f: f.write(f"// touched {k}.{j}\n")
    git("commit", "-q", "-a", "-m", f"Touch go files round {k}", date=f"{STAMP + (10 + k) * 86400} +0000")
for p, line in [("src/go/pkg01/f0030.go", "// uncommitted edit"), ("README.md", "uncommitted line")]:
    with open(os.path.join(dest, p), "a") as f: f.write(line + "\n")
open(os.path.join(dest, "notes.tmp"), "w").write("scratch\n")

for root, dirs, files in os.walk(dest):
    for n in dirs + files:
        try: os.utime(os.path.join(root, n), (STAMP, STAMP), follow_symlinks=False)
        except OSError: pass
os.utime(dest, (STAMP, STAMP))
open(os.path.join(dest, ".git", "fixture-ok"), "w").write(" ".join([str(SEED)] + sorted(BIG)))
print("fixture built:", dest)

#!/usr/bin/env python3
"""zash vs bash benchmark harness. See bench/run.sh --help."""
import argparse, json, math, os, re, shlex, shutil, statistics, subprocess, sys, tempfile, time, glob

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CATS = ["search", "text-pipeline", "fs-listing", "control-flow", "git", "startup"]

ap = argparse.ArgumentParser(prog="run.sh", description="verify zash output against bash, then time both")
ap.add_argument("--zash", default=os.environ.get("ZASH", os.path.join(ROOT, "zig-out/bin/zash")))
ap.add_argument("--bash", default=os.environ.get("BASH_BIN", shutil.which("bash")))
ap.add_argument("--corpus", default=os.path.join(HERE, "corpus"))
ap.add_argument("--fixture", default=os.environ.get("FIXTURE", os.path.join(HERE, ".fixture")))
ap.add_argument("--out", default=os.path.join(HERE, "results"))
ap.add_argument("--runs", type=int, default=int(os.environ.get("RUNS", "20")))
ap.add_argument("--warmup", type=int, default=int(os.environ.get("WARMUP", "3")))
ap.add_argument("--startup-runs", type=int, default=100)
ap.add_argument("--filter", help="regex on entry name")
ap.add_argument("--category", help="comma list of categories")
ap.add_argument("--check-only", action="store_true", help="verify outputs, skip timing")
ap.add_argument("--no-startup", action="store_true")
ap.add_argument("--no-hyperfine", action="store_true", help="use the built-in timing loop")
ap.add_argument("--timeout", type=int, default=120)
ap.add_argument("--big", default=os.environ.get("FIXTURE_BIG", ""), help="e.g. 50m,500m: build big logs, enable entries that need them")
ap.add_argument("--quick", action="store_true", help="runs=5 warmup=1 startup-runs=30")
ap.add_argument("-v", "--verbose", action="store_true")
a = ap.parse_args()
if a.quick:
    a.runs, a.warmup, a.startup_runs = 5, 1, 30

self_test = not (os.path.isfile(a.zash) and os.access(a.zash, os.X_OK))
if self_test:
    print(f"zash not found at {a.zash}: self-test mode (bash vs bash)", file=sys.stderr)
    a.zash = a.bash
use_hf = bool(shutil.which("hyperfine")) and not a.no_hyperfine

env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent-home", "LC_ALL": "C", "LANG": "C", "TZ": "UTC",
       "USER": "bench", "LOGNAME": "bench", "TERM": "dumb", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
       "GIT_PAGER": "cat", "PAGER": "cat", "GIT_OPTIONAL_LOCKS": "0"}
os.environ.clear(); os.environ.update(env)

gen_env = dict(os.environ, FIXTURE_BIG=a.big, PATH=env["PATH"])
r = subprocess.run([sys.executable, os.path.join(HERE, "fixture/gen.py"), a.fixture], env=dict(gen_env, HOME=os.path.expanduser("~")), capture_output=True, text=True)
if r.returncode: sys.exit("fixture generation failed:\n" + r.stderr)
fixture = os.path.realpath(a.fixture)
os.chdir(fixture)

def sh_argv(shell, script):
    return [shell, "--norc", "--noprofile", "-c", script] if shell == a.bash else [shell, "-c", script]

def norm(text, scratch):
    text = text.replace(scratch, "$SCRATCH").replace(fixture, "$FX")
    text = re.sub(r"(?m)^(?:\S*/)?(?:bash|zash)(?=: )", "SH", text)
    return text

def run_once(shell, script, scratch):
    e = dict(env, SCRATCH=scratch)
    try:
        p = subprocess.run(sh_argv(shell, script), env=e, stdin=subprocess.DEVNULL, capture_output=True, timeout=a.timeout)
    except subprocess.TimeoutExpired:
        return b"", b"timeout", 124
    return p.stdout, p.stderr, p.returncode

def pct(xs, q):
    xs = sorted(xs)
    i = min(len(xs) - 1, max(0, math.ceil(q * len(xs)) - 1))
    return xs[i]

def time_hf(cmds, runs, warmup):
    fd, path = tempfile.mkstemp(suffix=".json"); os.close(fd)
    args = ["hyperfine", "-N", "-i", "-w", str(warmup), "-r", str(runs), "--export-json", path, "--output", "null"]
    for c in cmds: args += [shlex.join(c)]
    p = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    try:
        res = json.load(open(path))["results"]
    finally:
        os.unlink(path)
    if p.returncode or len(res) != len(cmds):
        raise RuntimeError("hyperfine failed: " + p.stderr[-300:])
    return [r["times"] for r in res]

def time_loop(cmds, runs, warmup):
    out = [[] for _ in cmds]
    dn = os.open(os.devnull, os.O_RDWR)
    def once(c):
        t = time.perf_counter()
        pid = os.posix_spawn(c[0], c, os.environ, file_actions=[(os.POSIX_SPAWN_DUP2, dn, 0), (os.POSIX_SPAWN_DUP2, dn, 1), (os.POSIX_SPAWN_DUP2, dn, 2)])
        os.waitpid(pid, 0)
        return time.perf_counter() - t
    for c in cmds:
        for _ in range(warmup): once(c)
    for _ in range(runs):
        for i, c in enumerate(cmds): out[i].append(once(c))
    os.close(dn)
    return out

def timeit(cmds, runs, warmup):
    return (time_hf if use_hf else time_loop)(cmds, runs, warmup)

def stats(ts):
    return {"median": statistics.median(ts), "p95": pct(ts, 0.95), "min": min(ts), "mean": statistics.fmean(ts), "n": len(ts)}

def diff_snip(x, y, what):
    xl, yl = x.decode(errors="replace").splitlines(), y.decode(errors="replace").splitlines()
    for i in range(max(len(xl), len(yl))):
        l, r_ = xl[i] if i < len(xl) else "<eof>", yl[i] if i < len(yl) else "<eof>"
        if l != r_:
            return f"{what} line {i+1}: bash={l[:80]!r} zash={r_[:80]!r}"
    return what + " differs"

files = sorted(glob.glob(os.path.join(a.corpus, "*.sh")))
want_cats = set(a.category.split(",")) if a.category else None
results = []
skipped = 0
for f in files:
    name = os.path.basename(f)[:-3]
    if a.filter and not re.search(a.filter, name): continue
    text = open(f).read()
    cat = (re.search(r"^# cat: (\S+)", text, re.M) or [None, "text-pipeline"])[1]
    if want_cats and cat not in want_cats: continue
    req = re.findall(r"^# requires: (\S+)", text, re.M)
    if any(not os.path.exists(x) for x in req):
        skipped += 1; continue
    scratch = tempfile.mkdtemp(prefix="zbench.")
    ent = {"name": name, "category": cat}
    try:
        bo, be, bc = run_once(a.bash, text, scratch)
        b2 = run_once(a.bash, text, scratch)
        if (bo, be, bc) != b2 and norm(bo.decode(errors="replace"), scratch) != norm(b2[0].decode(errors="replace"), scratch):
            ent.update(status="NONDET", reason="bash output differs between two runs")
            results.append(ent); print(f"NONDET {name}", file=sys.stderr); continue
        zo, ze, zc = run_once(a.zash, text, scratch)
        bo, zo = norm(bo.decode(errors="replace"), scratch).encode(), norm(zo.decode(errors="replace"), scratch).encode()
        be, ze = norm(be.decode(errors="replace"), scratch).encode(), norm(ze.decode(errors="replace"), scratch).encode()
        why = None
        if bo != zo: why = diff_snip(bo, zo, "stdout")
        elif be != ze: why = diff_snip(be, ze, "stderr")
        elif bc != zc: why = f"exit status bash={bc} zash={zc}"
        if why:
            ent.update(status="FAIL", reason=why)
        elif a.check_only:
            ent.update(status="OK")
        else:
            tb, tz = timeit([sh_argv(a.bash, text), sh_argv(a.zash, text)], a.runs, a.warmup) if True else None
            sb, sz = stats(tb), stats(tz)
            ent.update(status="OK", bash=sb, zash=sz, speedup=sb["median"] / sz["median"] if sz["median"] > 0 else None, exit=bc)
    except Exception as ex:
        ent.update(status="FAIL", reason=f"harness error: {ex}")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    results.append(ent)
    if a.verbose or ent["status"] == "FAIL":
        print(f"{ent['status']:4} {name}" + (f"  {ent.get('reason','')}" if ent["status"] == "FAIL" else f"  x{ent.get('speedup') or 0:.2f}"), file=sys.stderr)

startup = []
if not a.no_startup and not a.check_only:
    cmds = [("-c true", "true"), ("-c 'echo hi'", "echo hi"), ("-c 'cd /; pwd'", "cd /; pwd"), ("empty script", ""), ("-c 'echo hi | head -1'", "echo hi | head -1"), ("-c 'x=1; [ $x = 1 ] && echo y'", "x=1; [ $x = 1 ] && echo y")]
    for label, script in cmds:
        ent = {"name": "startup " + label, "category": "startup"}
        try:
            ob, oz = run_once(a.bash, script, "/"), run_once(a.zash, script, "/")
            if (norm(ob[0].decode(errors="replace"), "/"), ob[2]) != (norm(oz[0].decode(errors="replace"), "/"), oz[2]):
                ent.update(status="FAIL", reason="output/exit differs")
            else:
                tb, tz = timeit([sh_argv(a.bash, script), sh_argv(a.zash, script)], a.startup_runs, max(a.warmup, 10))
                sb, sz = stats(tb), stats(tz)
                ent.update(status="OK", bash=sb, zash=sz, speedup=sb["median"] / sz["median"])
        except Exception as ex:
            ent.update(status="FAIL", reason=f"harness error: {ex}")
        startup.append(ent)
        if ent["status"] == "FAIL": print(f"FAIL {ent['name']}  {ent['reason']}", file=sys.stderr)
    results += startup

def geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else None

ok = [r for r in results if r["status"] == "OK" and r.get("speedup")]
nondet = [r for r in results if r["status"] == "NONDET"]
bad = [r for r in results if r["status"] == "FAIL"]
cats = {}
for c in sorted({r["category"] for r in results}, key=lambda c: CATS.index(c) if c in CATS else 99):
    rs = [r for r in results if r["category"] == c]
    g = [r for r in rs if r["status"] == "OK" and r.get("speedup")]
    cats[c] = {"entries": len(rs), "ok": len([r for r in rs if r["status"] == "OK"]), "fail": len([r for r in rs if r["status"] == "FAIL"]),
               "geomean_speedup": geomean([r["speedup"] for r in g]), "median_speedup": statistics.median([r["speedup"] for r in g]) if g else None}
summary = {"mode": "self-test (bash vs bash)" if self_test else "zash vs bash", "timer": "hyperfine" if use_hf else "builtin", "runs": a.runs, "warmup": a.warmup,
           "entries": len(results), "ok": len([r for r in results if r["status"] == "OK"]), "fail": len(bad), "nondeterministic": len(nondet), "skipped_missing_fixture": skipped,
           "geomean_speedup": geomean([r["speedup"] for r in ok])}
os.makedirs(a.out, exist_ok=True)
json.dump({"summary": summary, "categories": cats, "results": results}, open(os.path.join(a.out, "results.json"), "w"), indent=1)

def ms(x): return f"{x*1000:.2f}"
def fmt(x): return "n/a" if x is None else f"{x:.2f}x"
md = ["# zash vs bash", "", f"mode: {summary['mode']}, timer: {summary['timer']}, runs: {a.runs}, warmup: {a.warmup}", "",
      f"entries {summary['entries']}, verified {summary['ok']}, FAIL {summary['fail']}, nondeterministic {summary['nondeterministic']}, skipped (missing fixture) {skipped}, geomean speedup {fmt(summary['geomean_speedup'])}", "",
      "## Categories", "", "| category | entries | ok | fail | geomean | median |", "|---|---|---|---|---|---|"]
for c, v in cats.items():
    md.append(f"| {c} | {v['entries']} | {v['ok']} | {v['fail']} | {fmt(v['geomean_speedup'])} | {fmt(v['median_speedup'])} |")
if bad:
    md += ["", "## FAIL (output differs from bash, excluded from speedups)", "", "| entry | category | reason |", "|---|---|---|"]
    md += [f"| {r['name']} | {r['category']} | {r['reason'].replace('|', '/')} |" for r in bad]
if nondet:
    md += ["", "## NONDET (bash disagreed with itself, excluded)", ""] + [f"- {r['name']}" for r in nondet]
if ok:
    md += ["", "## Timings (sorted by speedup)", "", "| entry | category | bash med ms | bash p95 | zash med ms | zash p95 | speedup |", "|---|---|---|---|---|---|---|"]
    for r in sorted(ok, key=lambda r: -r["speedup"]):
        md.append(f"| {r['name']} | {r['category']} | {ms(r['bash']['median'])} | {ms(r['bash']['p95'])} | {ms(r['zash']['median'])} | {ms(r['zash']['p95'])} | {r['speedup']:.2f}x |")
open(os.path.join(a.out, "results.md"), "w").write("\n".join(md) + "\n")
print("\n".join(md[:14 + len(cats)]))
print(f"\nwrote {a.out}/results.md and results.json", file=sys.stderr)
sys.exit(1 if bad else 0)

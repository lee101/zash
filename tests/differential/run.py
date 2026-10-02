#!/usr/bin/env python3
"""Differential test runner: real bash is the oracle, zash must match stdout, stderr and exit status.

Cases: cases/<category>/<name>.sh  [+ <name>.stdin] [+ <name>.args (one argument per line)]
Id of a case is <category>/<name>.
"""
import argparse, difflib, fnmatch, json, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

ap = argparse.ArgumentParser(prog="run.sh", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("filters", nargs="*", help="substring/glob on case id (category/name); any match selects")
ap.add_argument("--zash", default=os.environ.get("ZASH", os.path.join(ROOT, "zig-out/bin/zash")))
ap.add_argument("--bash", default=os.environ.get("BASH_BIN", shutil.which("bash")))
ap.add_argument("--cases", default=os.path.join(HERE, "cases"))
ap.add_argument("-c", "--category", help="comma list of categories")
ap.add_argument("-j", "--jobs", type=int, default=min(16, os.cpu_count() or 4))
ap.add_argument("--timeout", type=float, default=10)
ap.add_argument("--known-failures", default=os.path.join(HERE, "known-failures.txt"), help="file of case ids/globs expected to fail")
ap.add_argument("--update-known-failures", action="store_true", help="rewrite the known-failures file with the current failing set")
ap.add_argument("--check", action="store_true", help="validate the cases themselves: bash vs bash in two dirs (determinism), flag vacuous cases")
ap.add_argument("-v", "--verbose", action="store_true", help="show diffs for unexpected failures")
ap.add_argument("--list", action="store_true")
ap.add_argument("--json", help="write results to this file")
a = ap.parse_args()

self_test = a.check or not (os.path.isfile(a.zash) and os.access(a.zash, os.X_OK))
if self_test and not a.check:
    print(f"zash not found at {a.zash}: self-test mode (bash vs bash)", file=sys.stderr)
zash = a.bash if self_test else a.zash

cases = []
for cat in sorted(os.listdir(a.cases)):
    cd = os.path.join(a.cases, cat)
    if not os.path.isdir(cd): continue
    if a.category and cat not in a.category.split(","): continue
    for f in sorted(os.listdir(cd)):
        if f.endswith(".sh"):
            cid = f"{cat}/{f[:-3]}"
            if a.filters and not any(x in cid or fnmatch.fnmatch(cid, x) for x in a.filters): continue
            cases.append((cat, cid, os.path.join(cd, f[:-3])))
if a.list:
    print("\n".join(c[1] for c in cases)); sys.exit(0)

known_pats = []
if os.path.exists(a.known_failures):
    for l in open(a.known_failures):
        l = l.split("#")[0].strip()
        if l: known_pats.append(l)
def is_known(cid): return any(fnmatch.fnmatch(cid, p) for p in known_pats)

def make_fixture(d):
    def w(p, s=""):
        p = os.path.join(d, p); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(s)
    w("a.txt", "alpha\nbeta\ngamma\ndelta\n")
    w("b.txt", "one two three\nfour five six\nseven eight nine\n")
    w("c.txt", "3\n1\n2\n10\n20\n")
    w("empty.txt")
    w("nonl.txt", "no newline at end")
    w("words.txt", "apple\nbanana\ncherry\napple\ndate\nbanana\napple\n")
    w("spaces.txt", "  lead and   multiple   spaces  \n\ttabbed\tline\t\n")
    w("data.csv", "id,name,score\n1,ann,90\n2,bob,85\n3,cy,70\n4,dee,85\n")
    w("kv.env", "A=1\nB=two\nC=three words\n")
    w("File With Spaces.txt", "spaced name\n")
    w(".hidden", "hidden\n")
    w("dir/x.txt", "x\n"); w("dir/y.log", "y\n"); w("dir/sub/z.txt", "z\n"); w("dir/sub/deep/w.md", "w\n")
    w("src/main.c", "int main() { return 0; }\n"); w("src/util.c", "void f() {}\n"); w("src/util.h", "void f();\n"); w("src/notes.md", "# notes\nTODO fix\n")
    w("sh/lib.sh", "libfn() { echo lib:$1; }\nLIBVAR=loaded\n")
    w("sh/hello.sh", "#!/bin/bash\necho hello from script \"$@\"\n")
    os.chmod(os.path.join(d, "sh/hello.sh"), 0o755)
    os.symlink("a.txt", os.path.join(d, "link.txt"))
    os.makedirs(os.path.join(d, "emptydir"), exist_ok=True)
    for n in ("f1.dat", "f2.dat", "f10.dat", "F3.dat", "g.dat"): w("globs/" + n, n + "\n")
    os.chmod(os.path.join(d, "sh"), 0o755)

fx_cache = tempfile.mkdtemp(prefix="zdiff-fx.")
make_fixture(fx_cache)

def norm(b, tmp):
    t = b.decode(errors="replace").replace(tmp, "$T")
    t = re.sub(r"(?m)^(?:\S*/)?(?:bash|zash)(?=: )", "SH", t)
    return t

def run_case(shell, base, tmp_parent):
    w = tempfile.mkdtemp(prefix="c.", dir=tmp_parent)
    work = os.path.join(w, "work")
    shutil.copytree(fx_cache, work, symlinks=True)
    shutil.copy(base + ".sh", os.path.join(w, "case.sh"))
    home = os.path.join(w, "home"); os.makedirs(home)
    args = []
    if os.path.exists(base + ".args"):
        args = open(base + ".args").read().split("\n")
        if args and args[-1] == "": args.pop()
    stdin = open(base + ".stdin", "rb") if os.path.exists(base + ".stdin") else subprocess.DEVNULL
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "USER": "tester", "LOGNAME": "tester", "TERM": "dumb"}
    argv = [shell, "--norc", "--noprofile", "../case.sh", *args] if shell == a.bash else [shell, "../case.sh", *args]
    try:
        p = subprocess.run(argv, cwd=work, env=env, stdin=stdin, capture_output=True, timeout=a.timeout)
        res = (norm(p.stdout, w), norm(p.stderr, w), p.returncode)
    except subprocess.TimeoutExpired:
        res = ("", "TIMEOUT", 124)
    finally:
        if hasattr(stdin, "close"): stdin.close()
        shutil.rmtree(w, ignore_errors=True)
    return res

def first_diff(x, y, what):
    d = list(difflib.unified_diff(x.splitlines(), y.splitlines(), "bash", "zash", lineterm="", n=1))
    return f"{what}:\n    " + "\n    ".join(d[:14]) if d else what

tmp_parent = tempfile.mkdtemp(prefix="zdiff.")
notes = []
def work(c):
    cat, cid, base = c
    try:
        b = run_case(a.bash, base, tmp_parent)
        z = run_case(zash, base, tmp_parent)
    except Exception as e:
        return cid, cat, "FAIL", f"harness error: {e}"
    why = None
    if a.check:
        if b != z: why = "NONDETERMINISTIC under bash: " + (first_diff(b[0], z[0], "stdout") if b[0] != z[0] else first_diff(b[1], z[1], "stderr") if b[1] != z[1] else "exit status")
        elif b[2] == 124: why = "bash timeout"
        elif not b[0] and not b[1] and b[2] == 0: why = "vacuous (no output, no stderr, exit 0)"
        if not why and (b[1] or b[2]): notes.append(f"{cid}: rc={b[2]} stderr={b[1].splitlines()[0][:90] if b[1] else ''}")
        return cid, cat, ("FAIL" if why else "PASS"), why
    if b[0] != z[0]: why = first_diff(b[0], z[0], "stdout")
    elif b[1] != z[1]: why = first_diff(b[1], z[1], "stderr")
    elif b[2] != z[2]: why = f"exit status: bash={b[2]} zash={z[2]}"
    return cid, cat, ("FAIL" if why else "PASS"), why

with ThreadPoolExecutor(a.jobs) as ex:
    out = list(ex.map(work, cases))
shutil.rmtree(tmp_parent, ignore_errors=True); shutil.rmtree(fx_cache, ignore_errors=True)

cats = {}
unexpected, xpass, failing = [], [], []
for cid, cat, st, why in out:
    c = cats.setdefault(cat, {"pass": 0, "fail": 0, "known": 0, "xpass": 0})
    if st == "PASS":
        if is_known(cid) and not a.check: c["xpass"] += 1; xpass.append(cid)
        else: c["pass"] += 1
    else:
        failing.append(cid)
        if is_known(cid) and not a.check: c["known"] += 1
        else: c["fail"] += 1; unexpected.append((cid, why))

print(f"{'category':<16}{'pass':>6}{'FAIL':>6}{'known':>7}{'xpass':>7}{'total':>7}")
tot = {"pass": 0, "fail": 0, "known": 0, "xpass": 0}
for cat, c in sorted(cats.items()):
    print(f"{cat:<16}{c['pass']:>6}{c['fail']:>6}{c['known']:>7}{c['xpass']:>7}{sum(c.values()):>7}")
    for k in tot: tot[k] += c[k]
print(f"{'TOTAL':<16}{tot['pass']:>6}{tot['fail']:>6}{tot['known']:>7}{tot['xpass']:>7}{sum(tot.values()):>7}")
mode = "check (bash vs bash, determinism)" if a.check else "self-test (bash vs bash)" if self_test else "zash vs bash"
print(f"mode: {mode}; conformance {100.0 * (tot['pass'] + tot['xpass']) / max(1, sum(tot.values())):.1f}% ({tot['pass'] + tot['xpass']}/{sum(tot.values())})")
if notes:
    print("\ninfo: cases where bash exits nonzero or writes stderr (confirm intended):\n  " + "\n  ".join(sorted(notes)))
if xpass:
    print("\nnow passing but listed in known failures (remove them):\n  " + "\n  ".join(xpass))
def brief(why):
    ls = (why or "").splitlines()
    for l in ls:
        t = l.strip()
        if (t.startswith("-") or t.startswith("+")) and not t.startswith(("---", "+++")): return f"{ls[0].rstrip(':')}: {t[:100]}"
    return ls[0] if ls else ""
for cid, why in unexpected:
    print(f"\nFAIL {cid}" + (f"\n  {why}" if (a.verbose or a.check) else f"  {brief(why)}"))
if a.json:
    json.dump({"mode": mode, "totals": tot, "categories": cats, "results": [{"id": c, "status": s, "known": is_known(c), "why": w} for c, _, s, w in out]}, open(a.json, "w"), indent=1)
if a.update_known_failures:
    hdr = [l.rstrip("\n") for l in open(a.known_failures) if l.startswith("#")] if os.path.exists(a.known_failures) else ["# cases expected to fail; one id (category/name) or glob per line"]
    open(a.known_failures, "w").write("\n".join(hdr + sorted(failing)) + "\n")
    print(f"\nwrote {len(failing)} entries to {a.known_failures}")
sys.exit(1 if unexpected else 0)

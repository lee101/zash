import os, sys, subprocess, shutil, tempfile, random, hashlib, itertools, time, importlib, filecmp

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(ROOT))
ZIG = os.path.expanduser("~/.local/opt/zig-0.16.0/zig")
ZUTIL = os.path.join(REPO, ".zig-cache", "zutil")
BIN = {
    "awk": "/usr/bin/mawk",
}
TIMEOUT = 60


def gnu_path(name):
    return BIN.get(name, "/usr/bin/" + name)


def build(optimize="ReleaseSafe", out=ZUTIL):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = [ZIG, "build-exe", "-target", "x86_64-linux-gnu", "-O", optimize, "-lc",
           "--dep", "registry", "-Mroot=" + os.path.join(ROOT, "zutil.zig"),
           "-Mregistry=" + os.path.join(REPO, "src/utils/registry.zig"),
           "-femit-bin=" + out, "--cache-dir", os.path.join(REPO, ".zig-cache")]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit("build failed")
    for f in os.listdir(os.path.dirname(out)):
        if f.endswith(".o"):
            try:
                os.unlink(os.path.join(os.path.dirname(out), f))
            except OSError:
                pass


class Case:
    def __init__(self, args, stdin=None, env=None, mutating=False, unsupported=False, tiny=True, label=None, sort_stderr=False, files_after=None):
        self.args = list(args)
        self.stdin = stdin
        self.env = env or {}
        self.mutating = mutating
        self.unsupported = unsupported
        self.tiny = tiny
        self.label = label
        self.sort_stderr = sort_stderr


def mkenv(extra, inbuf=None):
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": "/nonexistent", "TZ": "UTC"}
    env.update(extra)
    if inbuf:
        env["ZUTIL_INBUF"] = str(inbuf)
    return env


def supports(name, args, env):
    r = subprocess.run([ZUTIL, "--supports"] + args, env=mkenv(env), capture_output=True)
    return r.returncode == 0


def run_gnu(name, args, stdin, cwd, env):
    p = subprocess.run(args, executable=gnu_path(name), input=stdin, cwd=cwd, env=mkenv(env),
                       capture_output=True, timeout=TIMEOUT)
    return p.returncode, p.stdout, p.stderr


def run_zash(name, args, stdin, cwd, env, inbuf=None):
    p = subprocess.run([ZUTIL] + args, input=stdin, cwd=cwd, env=mkenv(env, inbuf),
                       capture_output=True, timeout=TIMEOUT)
    return p.returncode, p.stdout, p.stderr


def tree_digest(d):
    out = {}
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, d)
            if os.path.islink(p):
                out[rel] = ("link", os.readlink(p))
            else:
                with open(p, "rb") as fh:
                    out[rel] = hashlib.md5(fh.read()).hexdigest()
        for dd in dirs:
            out[os.path.relpath(os.path.join(root, dd), d) + "/"] = "dir"
    return out


def fixtures(dst, big=False):
    rnd = random.Random(1234)
    os.makedirs(dst, exist_ok=True)

    def w(name, data):
        path = os.path.join(dst, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)

    w("empty", b"")
    w("nl", b"\n")
    w("nonl", b"a\nb\nc")
    w("one", b"hello\n")
    w("onenonl", b"hello")
    w("lines5", b"one\ntwo\nthree\nfour\nfive\n")
    w("lines100", b"".join(b"line %d\n" % i for i in range(1, 101)))
    w("lines100nonl", b"".join(b"line %d\n" % i for i in range(1, 101))[:-1])
    w("crlf", b"a\r\nb\r\nc\r\n")
    w("blank", b"a\n\n\nb\n\n")
    w("numbers", b"".join(b"%d\n" % rnd.randint(-50, 5000) for _ in range(300)))
    w("longline", (b"x" * 300000) + b"\n" + b"short\n" + (b"y" * 70000))
    w("binary", bytes(rnd.randrange(256) for _ in range(5000)))
    w("bin_nul", b"text\n\x00bin\nmore\n")
    w("badutf8", b"ok\n\xff\xfe bad\n\xc3\x28 x\ncaf\xc3\xa9\n")
    w("utf8", "héllo wörld\n日本語テスト\nplain\n".encode())
    w("zeros", b"a\x00b\x00c\x00")
    w("words", b"the quick brown fox\njumps over the lazy dog\n  leading and   multiple   spaces\t tab\n\nlast line no newline")
    w("csv", b"id,name,score\n1,alice,90\n2,bob,85\n3,carol,\n4,dave,70,extra\n,,\nsolo\n")
    w("tsv", b"a\tb\tc\n1\t2\t3\nx\t\ty\n")
    w("colon", b"root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\nbin:x:2:2:bin:/bin:/usr/sbin/nologin\n")
    w("dups", b"b\na\na\nc\nc\nc\nB\nb\n\n\nz\n")
    w("sp name.txt", b"spaced name\n")
    w("dir/a.txt", b"alpha\nbeta\n")
    w("dir/b.log", b"error one\nwarn two\nerror three\n")
    w("dir/sub/c.txt", b"gamma\ndelta\nalpha\n")
    w("dir/sub/deep/d.md", b"# title\ntext alpha\n")
    w("dir/.hidden", b"secret alpha\n")
    w("dir/.git/config", b"[core]\n")
    w("code.py", b"import os\n\ndef foo(x):\n    return x + 1\n\nclass Bar:\n    def baz(self):\n        pass\n# TODO: fix\nprint(foo(2))\n")
    w("mixed", b"Apple pie\napple tart\nBanana split\nbanana bread\nCherry\n")
    os.makedirs(os.path.join(dst, "emptydir"), exist_ok=True)
    try:
        os.symlink("lines5", os.path.join(dst, "link5"))
        os.symlink("nonexistent_target", os.path.join(dst, "dangling"))
    except FileExistsError:
        pass
    if big:
        lines = []
        for i in range(400000):
            lines.append(b"%d line number %d some text here %d\n" % (rnd.randint(0, 99999), i, i % 977))
        w("big", b"".join(lines))
        w("big_nonl", b"".join(lines)[:-1])


def clone_tree(src, dst):
    shutil.copytree(src, dst, symlinks=True)


def decode(b):
    return b.decode("utf8", "replace")


class Stats:
    def __init__(self):
        self.total = 0
        self.passed = 0
        self.unsupported = 0
        self.failed = 0
        self.fails = []


def check(name, case, fxdir, stats, verbose=False):
    args = case.args
    sup = supports(name, args, case.env)
    if case.unsupported:
        stats.total += 1
        if sup:
            stats.failed += 1
            stats.fails.append((case, "claimed supported but should not be"))
        else:
            stats.passed += 1
        return
    if not sup:
        stats.unsupported += 1
        if verbose:
            print("  unsupported:", args)
        return
    variants = [None]
    if case.stdin is not None and case.tiny:
        variants += [7, 1]
    for inbuf in variants:
        stats.total += 1
        if case.mutating:
            with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
                d1 = os.path.join(t1, "w")
                d2 = os.path.join(t2, "w")
                clone_tree(fxdir, d1)
                clone_tree(fxdir, d2)
                a = run_gnu(name, args, case.stdin, d1, case.env)
                b = run_zash(name, args, case.stdin, d2, case.env, inbuf)
                same_tree = tree_digest(d1) == tree_digest(d2)
        else:
            a = run_gnu(name, args, case.stdin, fxdir, case.env)
            b = run_zash(name, args, case.stdin, fxdir, case.env, inbuf)
            same_tree = True
        ok_err = a[2] == b[2]
        if case.sort_stderr:
            ok_err = sorted(a[2].splitlines()) == sorted(b[2].splitlines())
        if a[0] == b[0] and a[1] == b[1] and ok_err and same_tree:
            stats.passed += 1
        else:
            stats.failed += 1
            why = []
            if a[0] != b[0]:
                why.append("status gnu=%d zash=%d" % (a[0], b[0]))
            if a[1] != b[1]:
                why.append("stdout differs gnu=%r zash=%r" % (a[1][:80], b[1][:80]))
            if not ok_err:
                why.append("stderr gnu=%r zash=%r" % (a[2][:300], b[2][:300]))
            if not same_tree:
                why.append("tree differs")
            stats.fails.append((case, ("; ".join(why))[:500] + (" [inbuf=%s]" % inbuf if inbuf else "")))


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("util", nargs="+")
    ap.add_argument("--nobuild", action="store_true")
    ap.add_argument("--big", action="store_true")
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--maxfail", type=int, default=12)
    a = ap.parse_args()
    if not a.nobuild:
        build()
    sys.path.insert(0, os.path.join(ROOT, "cases"))
    grand = 0
    with tempfile.TemporaryDirectory(prefix="zash_dt_") as tmp:
        fx = os.path.join(tmp, "fx")
        fixtures(fx, big=a.big)
        for u in a.util:
            mod = importlib.import_module(u)
            stats = Stats()
            t0 = time.time()
            import concurrent.futures, threading
            lock = threading.Lock()

            class LockedStats(Stats):
                pass

            def work(case):
                local = Stats()
                check(u, case, fx, local, a.v)
                with lock:
                    stats.total += local.total
                    stats.passed += local.passed
                    stats.unsupported += local.unsupported
                    stats.failed += local.failed
                    stats.fails += local.fails

            with concurrent.futures.ThreadPoolExecutor(max_workers=24) as ex:
                list(ex.map(work, mod.cases(fx)))
            print("%-8s total=%d pass=%d fail=%d unsupported-skipped=%d (%.1fs)" % (u, stats.total, stats.passed, stats.failed, stats.unsupported, time.time() - t0))
            seen = set()
            uniq = []
            for case, why in stats.fails:
                k = (tuple(case.args), case.stdin)
                if k in seen:
                    continue
                seen.add(k)
                uniq.append((case, why))
            if len(uniq) != len(stats.fails):
                print("  (%d distinct failing cases)" % len(uniq))
            for case, why in uniq[:a.maxfail]:
                print(("  FAIL %r stdin=%r: %s" % (case.args, (case.stdin or b"")[:12], why))[:330])
            grand += stats.failed
    sys.exit(1 if grand else 0)


if __name__ == "__main__":
    main()

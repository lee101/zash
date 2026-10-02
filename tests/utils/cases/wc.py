import itertools, os
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "lines5", "lines100", "crlf", "blank", "longline", "binary", "bin_nul", "badutf8", "utf8", "zeros", "words", "dir", "nofile", "emptydir", "sp name.txt", "csv", "tsv", "big", "link5"]
OPTS = [[], ["-l"], ["-w"], ["-c"], ["-m"], ["-L"], ["-lw"], ["-lc"], ["-wc"], ["-lwc"], ["-m", "-c"], ["-lm"], ["-wm"], ["-L", "-l"], ["-lwmcL"], ["--lines"], ["--words", "--bytes"], ["--chars"], ["--max-line-length"], ["-cl"]]
LOCS = ["C", "C.UTF-8", "en_AU.utf8"]

UNI = ("a b c d e f g h⁠i j　k l m n o p\u0085q\n" "日本 ́é \U0001f600 tab\there ééé\n").encode()


def cases(fx):
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, f))]
    for loc in LOCS:
        env = {"LC_ALL": loc}
        for f in files:
            for o in OPTS:
                yield Case(["wc"] + o + [f], env=env)
        for a, b in itertools.product(["lines5", "nonl", "empty", "nofile", "dir", "utf8", "one"], repeat=2):
            for o in [[], ["-l"], ["-m"], ["-L"], ["-wc"]]:
                yield Case(["wc"] + o + [a, b], env=env)
        yield Case(["wc"] + ["lines100", "utf8", "badutf8", "longline"], env=env)
        yield Case(["wc", "-l", "lines100", "utf8", "badutf8", "longline"], env=env)
        yield Case(["wc", "-c", "lines100", "utf8", "empty"], env=env)
        yield Case(["wc", "-lw", "lines5", "-", "nonl"], stdin=b"x y\nz\n", env=env)
        yield Case(["wc", "-l", "-"], stdin=b"x y\nz\n", env=env)
        yield Case(["wc", "-l", "lines5", "-"], stdin=b"x y\nz\n", env=env)
        yield Case(["wc", "-l", "/dev/null"], env=env)
        yield Case(["wc", "-lc", "/dev/null"], env=env)
        yield Case(["wc", "-l", "/dev/null", "lines5"], env=env)
        stdins = [b"", b"\n", b"a", b"a\n", b"a b\nc d e\n\n  \n", b"x" * 100000 + b"\ny z\n", b"\t\x01\x7f\x80\xff\r\n\x0c\x0b", bytes(range(256)) * 20, b"".join(b"line %d word\n" % i for i in range(3000)), UNI, UNI * 300, "日本語".encode() * 50000, b"\xe2\x82", b"a\xe2\x82", b"\xf0\x9f\x98", b"\xc3\xa9" * 20000 + b"\xc3"]
        for s in stdins:
            for o in OPTS:
                yield Case(["wc"] + o, stdin=s, env=env)
                yield Case(["wc"] + o + ["-"], stdin=s, env=env)
    yield Case(["wc", "--total=always", "lines5"], unsupported=True)
    yield Case(["wc", "--files0-from=-"], unsupported=True)
    yield Case(["wc", "-x"], unsupported=True)

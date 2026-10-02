import itertools, os
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "lines100nonl", "crlf", "blank", "longline", "binary", "bin_nul", "badutf8", "utf8", "zeros", "dir", "nofile", "link5", "dangling", "emptydir", "sp name.txt", "dups", "big"]
OPTS = [[], ["-n"], ["-b"], ["-s"], ["-E"], ["-T"], ["-v"], ["-A"], ["-e"], ["-t"], ["-u"], ["-ns"], ["-bs"], ["-nE"], ["-bE"], ["-sA"], ["-nA"], ["-nsvET"], ["-b", "-n"], ["-n", "-b"], ["--number"], ["--number-nonblank", "--squeeze-blank"], ["--show-all", "-n"], ["--show-ends"], ["--show-tabs"], ["--show-nonprinting", "-s"]]


def cases(fx):
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, f))]
    for f in files:
        for o in OPTS:
            yield Case(["cat"] + o + [f])
    pairs = ["lines5", "nonl", "empty", "nofile", "blank", "nl", "onenonl", "crlf", "dir"]
    for a, b in itertools.product(pairs, repeat=2):
        for o in [[], ["-n"], ["-s"], ["-b"], ["-sn"], ["-E"], ["-A"]]:
            yield Case(["cat"] + o + [a, b])
    for o in OPTS:
        yield Case(["cat"] + o + ["nonl", "-", "blank", "-"], stdin=b"x\n\n\ny")
    stdins = [b"", b"\n", b"a", b"a\n", b"\n\n\n\n", b"a\n\n\n\nb\n\n", b"x" * 100000 + b"\ny\n", b"\t\x01\x7f\x80\xff\r\n", bytes(range(256)) * 20, b"".join(b"line %d\n" % i for i in range(3000))]
    for s in stdins:
        for o in OPTS:
            yield Case(["cat"] + o, stdin=s)
            yield Case(["cat"] + o + ["-"], stdin=s)
    yield Case(["cat", "--", "-n"])
    yield Case(["cat", "lines5", "-n", "nonl"])
    yield Case(["cat", "-x"], unsupported=True)
    yield Case(["cat", "--help"], unsupported=True)
    yield Case(["cat", "--version"], unsupported=True)

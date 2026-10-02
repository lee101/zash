import itertools
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "lines100", "lines100nonl", "crlf", "blank", "longline", "binary", "bin_nul", "badutf8", "zeros", "dir", "nofile", "link5", "dangling", "emptydir", "sp name.txt", "big"]


def cases(fx):
    import os
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, "big"))]
    counts = ["0", "1", "2", "3", "5", "10", "11", "50", "100", "101", "1000", "-0", "-1", "-2", "-5", "-10", "-99", "-100", "-101", "-1000", "+3", "1K", "2b", "99999999999999999999", "-99999999999999999999"]
    for f in files:
        yield Case(["head", f])
        for c in counts:
            yield Case(["head", "-n", c, f])
            yield Case(["head", "-c", c, f])
        yield Case(["head", "-n3", f])
        yield Case(["head", "-c7", f])
        yield Case(["head", "--lines=2", f])
        yield Case(["head", "--bytes=-3", f])
        yield Case(["head", "-3", f])
        yield Case(["head", "-z", "-n", "2", f])
        yield Case(["head", "-z", "-n", "-1", f])
        yield Case(["head", "-v", "-n", "2", f])
        yield Case(["head", "-q", "-n", "2", f])
        yield Case(["head", "-n", "1", "-c", "4", f])
        yield Case(["head", "-c", "4", "-n", "1", f])
    for a, b in itertools.product(["lines5", "nonl", "empty", "nofile", "onenonl", "dir"], repeat=2):
        yield Case(["head", "-n", "2", a, b])
        yield Case(["head", a, b])
        yield Case(["head", "-q", "-n", "1", a, b])
        yield Case(["head", "-c", "3", a, b])
        yield Case(["head", "-n", "-1", a, b])
    yield Case(["head", "-n", "2", "lines5", "nonl", "one", "-v"])
    yield Case(["head", "-n", "2", "--", "lines5", "-"], stdin=b"x\ny\nz\n")
    stdins = [b"", b"\n", b"a", b"a\n", b"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", b"a\nb\nc", b"x" * 100000 + b"\ny\n", b"\n\n\n", b"a\x00b\n", bytes(range(256)) * 20]
    for s in stdins:
        yield Case(["head"], stdin=s)
        for c in ["0", "1", "3", "-1", "-3", "-100000"]:
            yield Case(["head", "-n", c], stdin=s)
            yield Case(["head", "-c", c], stdin=s)
        yield Case(["head", "-n", "2", "-"], stdin=s)
        yield Case(["head", "-v", "-n", "2"], stdin=s)
        yield Case(["head", "-n", "2", "lines5", "-", "nonl"], stdin=s)
        yield Case(["head", "-z", "-n", "1"], stdin=s)
    yield Case(["head", "-n", "x", "one"])
    yield Case(["head", "-c", "x", "one"])
    yield Case(["head", "-n", "", "one"])
    yield Case(["head", "-n", "-x", "one"])
    yield Case(["head", "-n", "5q", "one"])
    for e in ["C.UTF-8"]:
        yield Case(["head", "-n", "x", "one"], env={"LC_ALL": e})
        yield Case(["head", "nofile", "sp name.txt"], env={"LC_ALL": e})
    yield Case(["head", "nofile"], env={"LC_ALL": "C"})
    yield Case(["head", "no'file"])
    yield Case(["head", "no\nfile"])
    yield Case(["head", "-x"], unsupported=True)
    yield Case(["head", "--help"], unsupported=True)
    yield Case(["head", "lines5", "-3"], unsupported=True)
    yield Case(["head", "-n", "z"], unsupported=True)

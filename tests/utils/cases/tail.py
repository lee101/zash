import itertools, os
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "lines100", "lines100nonl", "crlf", "blank", "longline", "binary", "bin_nul", "badutf8", "zeros", "dir", "nofile", "link5", "dangling", "emptydir", "sp name.txt", "big", "big_nonl"]


def cases(fx):
    files = [f for f in FILES if not f.startswith("big") or os.path.exists(os.path.join(fx, f))]
    counts = ["0", "1", "2", "3", "5", "10", "11", "50", "100", "101", "1000", "+0", "+1", "+2", "+3", "+99", "+100", "+101", "+1000", "-1", "-3", "1K", "2b", "+1K", "70000", "+70000", "100000", "300000", "+300001"]
    for f in files:
        yield Case(["tail", f])
        for c in counts:
            yield Case(["tail", "-n", c, f])
            yield Case(["tail", "-c", c, f])
        yield Case(["tail", "-n3", f])
        yield Case(["tail", "-c7", f])
        yield Case(["tail", "--lines=2", f])
        yield Case(["tail", "--bytes=+3", f])
        yield Case(["tail", "-3", f])
        yield Case(["tail", "-z", "-n", "2", f])
        yield Case(["tail", "-z", "-n", "+2", f])
        yield Case(["tail", "-v", "-n", "2", f])
        yield Case(["tail", "-q", "-n", "2", f])
        yield Case(["tail", "-n", "1", "-c", "4", f])
        yield Case(["tail", "-c", "4", "-n", "1", f])
    for a, b in itertools.product(["lines5", "nonl", "empty", "nofile", "onenonl", "dir"], repeat=2):
        yield Case(["tail", "-n", "2", a, b])
        yield Case(["tail", a, b])
        yield Case(["tail", "-q", "-n", "1", a, b])
        yield Case(["tail", "-c", "3", a, b])
        yield Case(["tail", "-n", "+2", a, b])
    yield Case(["tail", "-n", "0", "nofile"])
    yield Case(["tail", "-c", "0", "lines5", "nofile"])
    yield Case(["tail", "-n", "+0", "lines5", "nofile"])
    yield Case(["tail", "-n", "2", "lines5", "nonl", "one", "-v"])
    yield Case(["tail", "-n", "2", "--", "lines5", "-"], stdin=b"x\ny\nz\n")
    yield Case(["tail", "-5", "--", "lines100"])
    yield Case(["tail", "-5", "lines100", "lines5"], unsupported=False)
    yield Case(["tail", "-5", "-"], stdin=b"1\n2\n3\n4\n5\n6\n7\n")
    stdins = [b"", b"\n", b"a", b"a\n", b"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", b"a\nb\nc", b"x" * 100000 + b"\ny\n", b"\n\n\n", b"a\x00b\n", bytes(range(256)) * 20, b"".join(b"%d\n" % i for i in range(5000))]
    for s in stdins:
        yield Case(["tail"], stdin=s)
        for c in ["0", "1", "3", "+1", "+3", "+100000", "100000", "4097"]:
            yield Case(["tail", "-n", c], stdin=s)
            yield Case(["tail", "-c", c], stdin=s)
        yield Case(["tail", "-n", "2", "-"], stdin=s)
        yield Case(["tail", "-v", "-n", "2"], stdin=s)
        yield Case(["tail", "-n", "2", "lines5", "-", "nonl"], stdin=s)
        yield Case(["tail", "-z", "-n", "1"], stdin=s)
    yield Case(["tail", "no'file"])
    yield Case(["tail", "-f", "lines5"], unsupported=True)
    yield Case(["tail", "-F", "lines5"], unsupported=True)
    yield Case(["tail", "-n", "z"], unsupported=True)
    yield Case(["tail", "lines5", "-3"], unsupported=True)
    yield Case(["tail", "-5", "-q", "lines5", "one"], unsupported=True)

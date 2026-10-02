import itertools, os
from harness import Case

FILES = ["empty", "nl", "nonl", "lines5", "csv", "tsv", "colon", "words", "crlf", "blank", "binary", "badutf8", "utf8", "zeros", "nofile", "dir", "longline", "big"]
LISTS = ["1", "2", "3", "1,3", "3,1", "1-2", "2-", "-2", "1-", "1-3,5", "2-4,3-6", "1-2,3-4", "5-9", "10", "100", "1,1,1", "2,2-3", "-1,3-", "4-4", "1,3-", "300000", "1-2,5,9-"]


def cases(fx):
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, f))]
    for f in files:
        for l in LISTS:
            yield Case(["cut", "-b" + l, f])
            yield Case(["cut", "-c", l, f])
            yield Case(["cut", "-b" + l, "--complement", f])
            yield Case(["cut", "-b" + l, "--output-delimiter=:", f])
            yield Case(["cut", "-c" + l, "--complement", "--output-delimiter=<>", f])
            yield Case(["cut", "-z", "-b" + l, f])
            for d in [",", ":", "\t", " "]:
                yield Case(["cut", "-d", d, "-f", l, f])
                yield Case(["cut", "-d" + d, "-f" + l, "-s", f])
            yield Case(["cut", "-f" + l, f])
            yield Case(["cut", "-d,", "-f" + l, "--complement", f])
            yield Case(["cut", "-d:", "-f" + l, "--complement", "-s", f])
            yield Case(["cut", "-d:", "-f" + l, "--output-delimiter=XY", f])
            yield Case(["cut", "-d,", "-f" + l, "--output-delimiter=", f])
            yield Case(["cut", "-z", "-d", ",", "-f" + l, f])
            yield Case(["cut", "--fields=" + l, "--delimiter=:", f])
            yield Case(["cut", "--bytes=" + l, f])
            yield Case(["cut", "--characters=" + l, f])
        yield Case(["cut", "-n", "-b1-3", f])
    for a, b in itertools.product(["csv", "nonl", "nofile", "dir"], repeat=2):
        yield Case(["cut", "-d,", "-f1", a, b])
        yield Case(["cut", "-b1-2", a, b])
    stdins = [b"", b"\n", b"a", b"a:b\n", b"a:b:c\nd\n:\n::\n", b"x," * 100000 + b"\ny,z\n", b"\x00a\x00b", b"a\tb\tc\n", b"abc\r\nd:e\r\n"]
    for s in stdins:
        for l in ["1", "2", "1-2", "2-", "-1", "1,3"]:
            for o in [["-b"], ["-c"], ["-d:", "-f"], ["-d,", "-f"], ["-f"], ["-z", "-d:", "-f"], ["-s", "-d:", "-f"], ["-z", "-b"]]:
                yield Case(["cut", o[0] + (l if len(o) == 1 else "")] + ([] if len(o) == 1 else []) if False else ["cut"] + o[:-1] + [o[-1] + l], stdin=s)
            yield Case(["cut", "-d:", "-f" + l, "-"], stdin=s)
    for bad in [["-f0"], ["-f2-1"], ["-b1", "-d,"], ["-f1", "-f2"], [], ["-d,,", "-f1"], ["-s", "-b1"], ["-d,", "-f"], ["-f1,"], ["-f-"], ["-b1-2", "-c3"], ["--help"], ["-d\n", "-f1"]]:
        yield Case(["cut"] + bad, unsupported=True)

import itertools, os, random
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "dups", "mixed", "csv", "tsv", "blank", "crlf", "binary", "bin_nul", "badutf8", "utf8", "zeros", "longline", "words", "nofile", "dir", "numbers"]
FLAGS = [[], ["-c"], ["-d"], ["-u"], ["-i"], ["-ci"], ["-di"], ["-ui"], ["-cd"], ["-cu"], ["-cdi"], ["-z"], ["-zc"], ["-f1"], ["-f2"], ["-s1"], ["-s2"], ["-w1"], ["-w3"], ["-w0"], ["-f1", "-s1"], ["-f1", "-w2"], ["-s1", "-w2"], ["-f1", "-s1", "-w2", "-c"], ["-ic", "-f1"], ["-f0"], ["-s0"], ["-f", "100"], ["-s", "1000"], ["--count"], ["--repeated"], ["--unique"], ["--ignore-case"], ["--skip-fields=1"], ["--skip-chars=1"], ["--check-chars=2"], ["--zero-terminated"], ["--count", "--ignore-case"]]


def cases(fx):
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, f))]
    for f in files:
        for fl in FLAGS:
            yield Case(["uniq"] + fl + [f])
        yield Case(["uniq", "-", f], stdin=b"a\na\n", mutating=True)
    yield Case(["uniq", "dups", "outf"], mutating=True)
    yield Case(["uniq", "-c", "dups", "outf"], mutating=True)
    yield Case(["uniq", "dups", "-"])
    yield Case(["uniq", "-", "-"], stdin=b"a\na\nb\n")
    yield Case(["uniq", "dups", "dups"], mutating=True)
    yield Case(["uniq", "nofile", "outf"], mutating=True)
    yield Case(["uniq", "dups", "/nonexistent/x"], mutating=True)
    yield Case(["uniq", "dups", "dir"], mutating=True)
    yield Case(["uniq", "dups", "emptydir"], mutating=True)
    rnd = random.Random(11)
    stdins = [
        b"", b"\n", b"\n\n", b"a", b"a\na", b"a\nb", b"a\n\n\nb\n\n", b"A\na\nB\nb\nb\n", b"a b\na c\nx b\n",
        b"  a b\n a c\nx\tb\n", b"a\x00b\na\x00c\n", b"aa\nab\nac\nbb\n", b"x 1\ny 1\nx 2\n",
        b"\xc3\xa9a\n\xc3\xa9b\n\xc3\x89a\n", b"a\r\na\r\nb\r\n", b"1\n1\n2\n2\n2\n3\n", b"a  b\na b\na\tb\n",
        b"abc def\nabd def\nabc xyz\n", b"\n \n  \n \t\n",
    ]
    for _ in range(4):
        stdins.append(b"".join(b"%s\n" % rnd.choice([b"a", b"b", b"A", b"B", b"a b", b"x y", b""]) for _ in range(rnd.randint(1, 300))))
    stdins.append(b"".join(b"k%d\n" % (i // 3) for i in range(30000)))
    stdins.append(b"x\n" * 200000)
    stdins.append(b"".join(bytes(rnd.choice(b"ab \t") for _ in range(rnd.randint(0, 6))) + b"\n" for _ in range(600)))
    for s in stdins:
        for fl in FLAGS:
            yield Case(["uniq"] + fl, stdin=s)
        yield Case(["uniq", "-z", "-f1"], stdin=s)
        yield Case(["uniq", "-z", "-s1", "-c"], stdin=s)
    for env in [{"LC_ALL": "C.UTF-8"}, {"LC_ALL": "en_US.UTF-8"}, {"LANG": "en_US.UTF-8"}]:
        for f in ["mixed", "utf8", "dups", "badutf8"]:
            for fl in [[], ["-i"], ["-f1"], ["-ic"], ["-s1"]]:
                yield Case(["uniq"] + fl + [f], env=env)
    for env in [{"LC_ALL": "de_DE.ISO-8859-1"}, {"LC_ALL": "", "LC_CTYPE": "fr_FR.ISO-8859-1"}]:
        yield Case(["uniq", "-i", "mixed"], env=env, unsupported=True)
        yield Case(["uniq", "-f1", "mixed"], env=env, unsupported=True)
    for bad in [["-D"], ["--all-repeated"], ["--group"], ["-d", "-u"], ["-f", "x"], ["-s", "-1"], ["-w", ""], ["-1"], ["+1"], ["-f"], ["--help"], ["--version"], ["a", "b", "c"], ["-f", "99999999999999999999"]]:
        yield Case(["uniq"] + bad, unsupported=True)

import itertools, os, random
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "lines100", "numbers", "dups", "mixed", "csv", "tsv", "colon", "words", "blank", "crlf", "binary", "bin_nul", "badutf8", "utf8", "zeros", "longline", "code.py", "nofile", "dir", "big"]
GLOBALS = [[], ["-r"], ["-u"], ["-ur"], ["-s"], ["-sr"], ["-n"], ["-nr"], ["-nu"], ["-f"], ["-fu"], ["-fr"], ["-b"], ["-bn"], ["-bf"], ["-nf"], ["-z"], ["-zu"], ["-sn"], ["-snr"]]
KEYS = ["1", "2", "1,1", "2,2", "1,2", "2,3", "1.2", "1.2,1.4", "2.2,2.3", "1,1n", "2n", "2,2nr", "1r", "1,1r", "2b", "2,2b", "1b,1b", "2,2bn", "3,3n", "1nr,2", "2.1b,2.3", "1,1f", "1f", "2,3f", "1.1,1.0", "1.3,2.0", "3,1", "1,1.0", "2,2.0", "1.1n", "1.2n,1.4"]
SEPS = [None, ",", ":", "\t", " ", "a", "0", "e"]


def cases(fx):
    files = [f for f in FILES if f != "big" or os.path.exists(os.path.join(fx, f))]
    for f in files:
        for g in GLOBALS:
            yield Case(["sort"] + g + [f])
        for sep in SEPS:
            sa = [] if sep is None else ["-t", sep]
            for k in KEYS:
                if f in ("big", "longline", "binary", "badutf8", "lines100") and k not in ("2", "2,2n", "1,1", "1.2,1.4", "2b", "2,2nr"):
                    continue
                yield Case(["sort"] + sa + ["-k", k, f])
            yield Case(["sort"] + sa + ["-k2,2n", "-k1,1", f])
            yield Case(["sort"] + sa + ["-r", "-k2,2n", f])
            yield Case(["sort"] + sa + ["-r", "-k2", f])
            yield Case(["sort"] + sa + ["-n", "-k2", f])
            yield Case(["sort"] + sa + ["-nr", "-k2", f])
            yield Case(["sort"] + sa + ["-b", "-k2", f])
            yield Case(["sort"] + sa + ["-b", "-k2,2", "-k1,1r", f])
            yield Case(["sort"] + sa + ["-u", "-k2,2", f])
            yield Case(["sort"] + sa + ["-u", "-s", "-k1,1", f])
            yield Case(["sort"] + sa + ["-s", "-k1,1", f])
            yield Case(["sort"] + sa + ["-s", "-k1,1r", f])
            yield Case(["sort"] + sa + ["-snr", "-k2,2", f])
            yield Case(["sort"] + sa + ["-f", "-k2", f])
            yield Case(["sort"] + sa + ["-ru", "-k1,1n", f])
        yield Case(["sort", "-c", f])
        yield Case(["sort", "-C", f])
        yield Case(["sort", "-cu", f])
        yield Case(["sort", "-cr", f])
        yield Case(["sort", "-cn", f])
        yield Case(["sort", "-ck2,2", f])
        yield Case(["sort", "--check=quiet", f])
        yield Case(["sort", "--check=silent", f])
        yield Case(["sort", "--check=diagnose-first", f])
        yield Case(["sort", "--numeric-sort", "--reverse", "--unique", f])
        yield Case(["sort", "--key=2,2", "--field-separator=,", "--stable", f])
        yield Case(["sort", "--ignore-case", "--ignore-leading-blanks", f])
        yield Case(["sort", "--zero-terminated", f])
        yield Case(["sort", "--sort=numeric", f])
        yield Case(["sort", "-S", "1M", "-T", "/tmp", f])
        yield Case(["sort", "-S1K", "--parallel=2", f])
        yield Case(["sort", "-o", "outf", f], mutating=True)
        yield Case(["sort", "-o", f, f], mutating=True)
        yield Case(["sort", "-r", "-o", "outf", f], mutating=True)
    for a, b in itertools.product(["csv", "nonl", "one", "nofile", "dir", "empty", "dups"], repeat=2):
        yield Case(["sort", a, b])
        yield Case(["sort", "-u", a, b])
        yield Case(["sort", "-n", a, b])
        yield Case(["sort", "-c", a, b], unsupported=True)
        yield Case(["sort", "-o", "outf", a, b], mutating=True)
    yield Case(["sort", "-", "nonl", "-"], stdin=b"z\ny\nx")
    yield Case(["sort", "nonl", "-"], stdin=b"z\ny\nx")
    yield Case(["sort", "-o", "outf", "nofile"], mutating=True)
    yield Case(["sort", "-o", "dir", "one"], mutating=True)
    yield Case(["sort", "-o", "/nonexistent/x", "one"], mutating=True)
    yield Case(["sort", "-c", "nofile"])
    yield Case(["sort", "-c", "dir"])
    yield Case(["sort", "-k1", "--", "-r"])
    yield Case(["sort", "one", "-r"])
    yield Case(["sort", "-n", "-n", "-r", "-r", "numbers"])
    rnd = random.Random(7)
    stdins = [
        b"", b"\n", b"\n\n", b"a", b"b\na", b"a\n\nb\n", b"B\na\nA\nb\n", b"\x00\n\xff\n\x01\n",
        b"10\n9\n8\n-1\n-0\n0\n+5\n1.5\n1.50\n.5\n-.5\n5.\n  7\n\t3\n1e3\n0x10\n-\n-.\n.\n 12abc\n--5\n- 5\n007\n7\n-007\n",
        b"1,5\n1.5\n1,5.5\n1 000\n1\xa02\n",
        b"99999999999999999999\n99999999999999999998\n-99999999999999999999\n123456789012345678\n123456789012345679\n1234567890123456789\n-1234567890123456789\n",
        b"0.000000000000000000001\n0.00000000000000000001\n0\n-0.0\n0.0\n00.00\n",
        b"a b\na  b\na\tb\n a b\nab\n",
        b"x\ty\nx y\nx  y\n",
        b"k 1\nk 10\nk 2\nK 1\nk 1\n",
        b"abcdefgh\nabcdefghi\nabcdefg\nabcdefgh\x00\nabcdefgh\x00\x00\nabcdefghij\nabcdefgi\n",
        b"_\n[\n`\n{\nZ\na\nz\nA\n@\n",
        b"\xc3\xa9\ne\nz\n\xc3\xa0\n\xe6\x97\xa5\n",
        b"a\r\nb\r\na\r\n",
        b"1 2 3\n1 2 4\n1 3 1\n0 9 9\n",
        b"  a\n a\na\n \ta\n",
        b"a:1:x\na:10:y\nb:2:z\na:1:w\n:3:\n::\n",
        b"abc\nab\nabd\n",
    ]
    for _ in range(6):
        stdins.append(b"".join(b"%d %s\n" % (rnd.randint(-50, 50), rnd.choice([b"a", b"B", b"c", b"A", b""])) for _ in range(rnd.randint(1, 400))))
    stdins.append(b"".join(b"k%d\n" % rnd.randint(0, 5000) for _ in range(20000)))
    stdins.append(b"".join(bytes(rnd.choice(b"ab c\t") for _ in range(rnd.randint(0, 12))) + b"\n" for _ in range(500)))
    stdins.append(b"".join(bytes(rnd.choice(b"01 .-\t,") for _ in range(rnd.randint(0, 9))) + b"\n" for _ in range(800)))
    for s in stdins:
        for g in GLOBALS:
            yield Case(["sort"] + g, stdin=s)
        for k in KEYS:
            yield Case(["sort", "-k", k], stdin=s)
            yield Case(["sort", "-k", k, "-u"], stdin=s)
            yield Case(["sort", "-s", "-k", k], stdin=s)
            yield Case(["sort", "-r", "-k", k], stdin=s)
            yield Case(["sort", "-n", "-k", k], stdin=s)
            yield Case(["sort", "-b", "-k", k], stdin=s)
            yield Case(["sort", "-t", " ", "-k", k], stdin=s)
            yield Case(["sort", "-t", ",", "-k", k], stdin=s)
        yield Case(["sort", "-k1,1n", "-k2,2"], stdin=s)
        yield Case(["sort", "-k2,2", "-k1,1n"], stdin=s)
        yield Case(["sort", "-k1,1", "-k1,1"], stdin=s)
        yield Case(["sort", "-k1n", "-k2n", "-k3n"], stdin=s)
        yield Case(["sort", "-c"], stdin=s)
        yield Case(["sort", "-cu"], stdin=s)
        yield Case(["sort", "-cn"], stdin=s)
        yield Case(["sort", "-cr"], stdin=s)
        yield Case(["sort", "-C"], stdin=s)
        yield Case(["sort", "-z"], stdin=s)
        yield Case(["sort", "-z", "-n"], stdin=s)
        yield Case(["sort", "-z", "-k2"], stdin=s)
        yield Case(["sort", "-z", "-b", "-k2"], stdin=s)
        yield Case(["sort", "-z", "-t", " ", "-k2"], stdin=s)
    for env in [{"LC_ALL": "C.UTF-8"}, {"LC_ALL": "POSIX"}, {"LANG": "C", "LC_ALL": ""}]:
        for f in ["lines5", "numbers", "badutf8", "utf8", "binary", "mixed", "colon", "dups"]:
            for g in [[], ["-r"], ["-n"], ["-f"], ["-u"], ["-k2"], ["-t:", "-k2,2n"]]:
                yield Case(["sort"] + g + [f], env=env)
    for env in [{"LC_ALL": "en_US.UTF-8"}, {"LC_ALL": "", "LC_COLLATE": "en_US.UTF-8"}, {"LC_ALL": "", "LANG": "en_US.UTF-8"}, {"LC_ALL": "C", "POSIXLY_CORRECT": "1"}, {"_POSIX2_VERSION": "199209"}, {"LC_NUMERIC": "de_DE.UTF-8", "LC_ALL": ""}]:
        yield Case(["sort", "mixed"], env=env, unsupported=True)
    for bad in [["+1"], ["-h"], ["-V"], ["-g"], ["-M"], ["-R"], ["-d"], ["-i"], ["-m"], ["-k0"], ["-k1,0"], ["-k1.0"], ["-kx"], ["-k"], ["-t", "ab"], ["-t", ""], ["-t", ",", "-t", ":"], ["-k1h"], ["-k1d"], ["-k1V"], ["--files0-from=x"], ["--debug"], ["-S", "x"], ["-S", "0"], ["--parallel=0"], ["--sort=month"], ["--sort=random"], ["--check=bogus"], ["-c", "-o", "x"], ["--help"], ["--version"], ["-k1", "-k2", "-k3", "-k4", "-k5", "-k6", "-k7", "-k8", "-k9"], ["-k1.1b2"], ["--random-source=x"], ["-c", "-z"]]:
        yield Case(["sort"] + bad + ["one"], unsupported=True)

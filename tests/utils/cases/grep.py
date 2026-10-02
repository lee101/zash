import itertools, os
from harness import Case

FILES = ["g1", "g2", "gnonl", "gtext", "gdense", "empty", "nl", "lines5", "words", "code.py", "mixed", "crlf", "blank", "longline", "binary", "bin_nul", "badutf8", "utf8", "nofile", "dir", "emptydir", "invalid8", "utf8mix", "nulbig", "nulbig2"]
BRE = ["foo", "o", "^foo", "foo$", "^$", ".", "..*", "fo*", "fo\\+", "foo\\|bar", "\\(fo\\)o", "f.o", "[a-c]", "[^a-z]", "[[:upper:]]", "[[:digit:]]", "\\bfoo\\b", "\\<foo", "foo\\>", "\\w\\+", "a*", "x*", "^", "$", "foo.*bar", "fo\\{2\\}", "fo\\{1,2\\}", "\\(a\\|b\\)c", "TAB", "bar foo", "o.o", "[[:space:]]foo", "^[[:space:]]*$", "e$", "\\.", "\\*", "a\\.b", "*foo", "^*", "[]]", "[a-]", "foo\\(bar\\)\\?", "fo\\?o", "\\(foo\\)\\{2\\}", "^\\(.*\\)o$", "ba[rz]", "[[:alpha:]]\\{3\\}", "\\W", "\\s", "\\S\\+"]
ERE = ["foo", "foo|bar", "(fo)+o", "f.o", "fo+", "fo?o", "^foo$", "[a-c]+", "a{2}", "o{1,2}", "(a|b)c", "\\bfoo\\b", "\\<foo\\>", "x*", "^$", "^", "$", "foo.*bar", "(foo|bar) (foo|baz)", "\\.", "a{,2}b", "a{1", "{", "foo{", "[0-9]+", "(^| )foo", "foo( |$)", "(a|b|c)+", "^(.*)o$", "\\w+", "()", "a|", "|a", "(a|)b", "[[:alpha:]]+", "\\s+", "b?a?r", "foo$|^bar"]
FIXED = ["a*", "o+", "f?o", "[a]", "foo",  "o", "foo.bar", "a.b", ".", "", "foo bar", "*", "\\", "foo\nbar", "bar\nfoo"]


def cases(fx):
    files = [f for f in FILES if f not in ("nulbig", "nulbig2") or os.path.exists(os.path.join(fx, f))]
    quick = ["g1", "g2", "gtext", "gnonl", "empty", "binary", "utf8mix", "nofile", "dir"]
    for pat in BRE:
        for f in quick:
            yield Case(["grep", pat, f])
        for f in ["g2", "gtext", "mixed", "words"]:
            for o in ["-n", "-c", "-v", "-i", "-w", "-x", "-o", "-on", "-vn", "-ob", "-l", "-L", "-q", "-nb", "-iw", "-ix", "-vc", "-ow", "-oi"]:
                yield Case(["grep", o, pat, f])
    for pat in ERE:
        for f in quick:
            yield Case(["grep", "-E", pat, f])
        for f in ["g2", "gtext", "mixed", "words"]:
            for o in ["-n", "-c", "-v", "-i", "-w", "-x", "-o", "-on", "-vn", "-ob", "-ow", "-oi", "-ix"]:
                yield Case(["grep", "-E", o, pat, f])
    for pat in FIXED:
        for f in quick:
            yield Case(["grep", "-F", pat, f])
        for f in ["g2", "gtext", "mixed"]:
            for o in ["-n", "-c", "-v", "-i", "-w", "-x", "-o", "-ow", "-oi", "-ix"]:
                yield Case(["grep", "-F", o, pat, f])
    for f in files:
        for o in [[], ["-n"], ["-c"], ["-l"], ["-L"], ["-q"], ["-v"], ["-vc"], ["-o"], ["-b"], ["-nb"], ["-a"], ["-ac"], ["-I"], ["-Ic"], ["-m1"], ["-m2", "-n"], ["-m0"], ["-s"], ["-H"], ["-h"], ["-Hn"], ["-Z", "-l"], ["-Z", "-H"], ["-Zc"], ["--binary-files=text"], ["--binary-files=without-match"], ["-A1"], ["-B1"], ["-C1"], ["-n", "-C2"], ["-vn", "-C1"], ["-A2", "-m1"], ["-c", "-m1"], ["-o", "-n"]]:
            yield Case(["grep"] + o + ["foo", f])
            yield Case(["grep"] + o + ["^", f])
    ctxcounts = ["0", "1", "2", "3", "5", "100"]
    for f in ["g1", "gdense", "gtext", "lines100", "gnonl", "g2"]:
        for pat in ["foo", "e", "line 5", "line 50", "zzz", "^$"]:
            for c in ctxcounts:
                for o in ["-A", "-B", "-C"]:
                    yield Case(["grep", "-n", o + c, pat, f])
                yield Case(["grep", "-" + c, pat, f])
            yield Case(["grep", "-A1", "-B3", "-n", pat, f])
            yield Case(["grep", "-B2", "-A0", pat, f])
            yield Case(["grep", "-vn", "-C1", pat, f])
            yield Case(["grep", "-vn", "-A2", pat, f])
            yield Case(["grep", "-vn", "-B2", pat, f])
            yield Case(["grep", "-C1", "-m2", "-n", pat, f])
            yield Case(["grep", "-A3", "-m1", "-n", pat, f])
            yield Case(["grep", "-nb", "-C1", pat, f])
            yield Case(["grep", "-C1", "--group-separator=XX", pat, f])
            yield Case(["grep", "-C1", "--no-group-separator", pat, f])
            yield Case(["grep", "-C1", "-c", pat, f])
            yield Case(["grep", "-C1", "-l", pat, f])
    multi = [["g1", "g2"], ["g1", "nofile", "g2"], ["g1", "empty", "gnonl"], ["g1", "dir", "g2"], ["g1", "-", "g2"], ["binary", "g1"], ["bin_nul", "g2", "g1"]]
    for fs in multi:
        for o in [[], ["-n"], ["-c"], ["-l"], ["-L"], ["-h"], ["-H"], ["-A1"], ["-C1", "-n"], ["-s"], ["-q"], ["-o"], ["-m1"], ["-b"], ["-Zl"], ["-Zn"], ["-vc"]]:
            yield Case(["grep"] + o + ["foo"] + fs, stdin=b"foo stdin\nx\nfoo2\n")
    for stdin in [b"", b"foo", b"foo\n", b"a\nfoo\nb", b"\n\n", b"foo\x00bar\nfoo\n", b"x\n\xff\nfoo\n", b"\xc3\xa9 foo\n", b"foo\r\nbar\r\n", b"a" * 200000 + b"foo\n"]:
        for o in [[], ["-n"], ["-c"], ["-H"], ["-l"], ["-L"], ["--label=LBL", "-H"], ["-o"], ["-v"], ["-b"], ["-q"], ["-x"], ["-w"], ["-i"], ["-a"], ["-A1"]]:
            yield Case(["grep"] + o + ["foo"], stdin=stdin)
            yield Case(["grep"] + o + ["foo", "-"], stdin=stdin)
    yield Case(["grep", "-e", "foo", "-e", "bar", "g2"])
    yield Case(["grep", "-e", "foo", "-e", "^b", "-n", "g2", "gtext"])
    yield Case(["grep", "-E", "-e", "a+", "-e", "b$", "g1"])
    yield Case(["grep", "-F", "-e", "foo", "-e", "bar", "-o", "g2"])
    yield Case(["grep", "--", "-x", "g2"])
    yield Case(["grep", "-e", "-x", "g2"])
    yield Case(["grep", "foo", "g2", "-n"])
    yield Case(["grep", "--regexp=foo", "--line-number", "g2"])
    yield Case(["grep", "--count", "--ignore-case", "foo", "g2"])
    yield Case(["grep", "--invert-match", "--word-regexp", "foo", "g2"])
    yield Case(["grep", "--max-count=1", "foo", "g2"])
    yield Case(["grep", "--only-matching", "--with-filename", "foo", "g2"])
    yield Case(["grep", "--files-with-matches", "foo", "g1", "g2", "lines5"])
    yield Case(["grep", "--files-without-match", "foo", "g1", "g2", "lines5"])
    yield Case(["grep", "--no-filename", "foo", "g1", "g2"])
    yield Case(["grep", "--context=1", "foo", "g1"])
    yield Case(["grep", "--color=never", "foo", "g1"])
    yield Case(["grep", "--colour=never", "foo", "g1"])
    yield Case(["grep", "-y", "FOO", "g2"])
    yield Case(["grep", "-nH", "foo", "g1"])
    yield Case(["grep", "-in", "FOO", "g2", "g1"])
    yield Case(["grep", "-e", "", "g1"])
    yield Case(["grep", "", "g1"])
    yield Case(["grep", "-c", "", "empty", "nl", "g1"])
    yield Case(["grep", "-v", "", "g1"])
    yield Case(["grep", "-vc", "", "g1"])
    yield Case(["grep", "-x", "", "blank"])
    yield Case(["grep", "-w", "", "g1"], unsupported=True)
    yield Case(["grep", "-E", "a{1,2", "g1"])
    yield Case(["grep", "-o", "", "g1"])
    yield Case(["grep", "-on", "x*", "g1"])
    yield Case(["grep", "-o", "-b", "o", "g2"])
    yield Case(["grep", "-o", "-i", "foo", "g2"])
    yield Case(["grep", "-o", "-w", "foo", "g2", "gtext"])
    yield Case(["grep", "-ow", "-E", "fo+|foo bar", "g2"])
    # recursion
    for o in [[], ["-n"], ["-l"], ["-c"], ["-L"], ["-h"], ["-H"], ["-i"], ["-s"], ["-q"], ["-a"], ["-I"]]:
        for targets in [["rtree"], ["rtree/"], ["rtree/a", "rtree/c"], ["rtree/x.txt"], ["rtree", "g1"], ["."], ["dir"], ["nofile", "rtree"]]:
            yield Case(["grep", "-r"] + o + ["foo"] + targets)
            yield Case(["grep", "-R"] + o + ["foo"] + targets)
    for inc in [["--include=*.txt"], ["--include=*.log"], ["--include=x*"], ["--exclude=*.txt"], ["--exclude=z*"], ["--exclude=a*"], ["--exclude-dir=a"], ["--exclude-dir=b"], ["--exclude-dir=a*"], ["--exclude-dir=.hid"], ["--exclude-dir=a", "--exclude=*.log"], ["--include=*.txt", "--include=*.log"], ["--exclude=*.txt", "--exclude=*.log"], ["--exclude-dir=rtree"], ["--exclude-dir=."], ["--exclude=x.txt"], ["--exclude=rtree/x.txt"], ["--include=*"], ["--exclude=*"]]:
        for targets in [["rtree"], ["rtree/x.txt", "rtree/y.log"], ["."], ["rtree", "rtree/a"], ["rtree/a/"]]:
            yield Case(["grep", "-r", "-l"] + inc + ["foo"] + targets)
    yield Case(["grep", "-d", "skip", "foo", "rtree", "g1"])
    yield Case(["grep", "-d", "read", "foo", "rtree", "g1"])
    yield Case(["grep", "-d", "recurse", "foo", "rtree"])
    yield Case(["grep", "--directories=skip", "foo", "rtree"])
    # utf8
    for loc in ["C.UTF-8"]:
        env = {"LC_ALL": loc}
        for pat in ["foo", ".", "caf.", "caf.$", "na.ve", "^.....$", "[^a-z]", "[a-z]*", ".*foo", "\\xc3", "é", "café", "日.", "xé*", "o"]:
            for f in ["utf8mix", "invalid8", "g1", "badutf8", "utf8"]:
                yield Case(["grep", pat, f], env=env)
                yield Case(["grep", "-c", pat, f], env=env)
                yield Case(["grep", "-o", pat, f], env=env)
                yield Case(["grep", "-on", pat, f], env=env)
                yield Case(["grep", "-v", pat, f], env=env)
                yield Case(["grep", "-vn", "-C1", pat, f], env=env)
                yield Case(["grep", "-a", pat, f], env=env)
        yield Case(["grep", "-w", "foo", "utf8mix"], env=env, unsupported=True)
        for pat in ["caf\u00e9", "\u00c9cole", "\u00fcber", "stra\u00dfe", "strasse", "istanbul", "\u0130stanbul", "s", "k", "\u03c3", "\u03a3", "\u03b1\u03b2", "\u043f\u0440\u0438\u0432\u0435\u0442", "[[:alpha:]]\\+", "[[:upper:]]", "[[:lower:]]\\+", "[[:digit:]]", "[[:alnum:]]*", "[[:punct:]]", "[[:space:]]", "\\w\\+", "\\W", "\\s", "\\S\\+", "[\u00e9\u00e8]", "[^\u00e9a-z ]", "\u00e9*", "\u4e2d.", ".\u6587", "x.", "^.\\{3\\}$", "[[:print:]]*", "[[:graph:]]\\+", "[[:cntrl:]]", "[[:blank:]]", "\u00b2", "\u2467", "[0-9]\\+"]:
            for f in ["unitext", "utf8mix", "invalid8"]:
                for o in [[], ["-o"], ["-c"], ["-i"], ["-io"], ["-v"], ["-ion"], ["-E"], ["-Eo"], ["-F"], ["-Fi"], ["-x"], ["-ix"]]:
                    yield Case(["grep"] + o + [pat, f], env=env)
        for loc2 in ["en_AU.utf8"]:
            for pat in ["caf\u00e9", "[[:alpha:]]\\+", "\\w\\+", "\u00fcber"]:
                for o in [["-i"], ["-io"], []]:
                    yield Case(["grep"] + o + [pat, "unitext"], env={"LC_ALL": loc2})
    # unsupported
    for bad in [["-P", "foo", "g1"], ["-E", "(a)\\1", "g1"], ["--color=always", "foo", "g1"], ["-z", "foo", "g1"], ["-f", "g1", "g2"], ["foo", "-T", "g1"], ["-E", "*a", "g1"], ["--help"], ["-V"], ["-e"], ["-A", "x", "foo", "g1"], ["-m", "x", "foo", "g1"], ["-o", "-v", "foo", "g1"], ["-o", "-C1", "foo", "g1"], ["--exclude=a", "--include=b", "foo", "g1"], ["-E", "[", "g1"], ["foo\\(", "g1"], ["[[:foo:]]", "g1"], ["--binary-files=bogus", "foo", "g1"], ["-d", "bogus", "foo", "g1"], ["-D", "skip", "foo", "g1"]]:
        yield Case(["grep"] + bad, unsupported=True)

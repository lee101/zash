import itertools
from harness import Case

FILES = ["empty", "nl", "nonl", "one", "onenonl", "lines5", "lines100", "lines100nonl", "crlf", "blank", "words", "csv", "colon", "dups", "mixed", "code.py", "g1", "gnonl", "gtext", "dir", "nofile", "binary", "bin_nul", "link5", "sp name.txt"]

SCRIPTS = [
    "p", "d", "=", "n", "N", "g", "G", "h", "H", "x", "P", "D", "q", "Q", "q3", "Q7", "$!N", "$!d", "$d", "1d", "2q", "3p",
    "s/e/E/", "s/e/E/g", "s/e/E/2", "s/e/E/2g", "s/e/E/3", "s/e/&&/", "s/e/\\&/", "s/./X/", "s/./X/g", "s/.*/<&>/", "s/^/> /", "s/$/ </", "s/^$/EMPTY/",
    "s/[aeiou]/_/g", "s/[^a-z]/-/g", "s/[[:digit:]]\\+/N/g", "s/[[:space:]]*$//", "s/^[[:space:]]*//", "s/\\(.\\)\\(.\\)/\\2\\1/", "s/\\(.*\\) \\(.*\\)/\\2 \\1/",
    "s/o\\{2\\}/00/g", "s/x*/-/g", "s/b*/X/g", "s/a*/X/2", "s/\\bt/T/g", "s/\\w\\+/[&]/g", "s/\\<./\\u&/g", "s/.*/\\U&/", "s/.*/\\L&/", "s/\\(.\\)\\(.*\\)/\\U\\1\\E\\2/", "s/\\(^.\\)/\\l\\1/",
    "s/e/E/p", "s/e/E/gp", "s/e/E/I", "s/E/x/Ig", "s/E/x/i", "s,a,b,", "s#a#b#g", "s|a|b|", "s_a_b_", "s/a/\\n/", "s/ /\\n/g", "s/a/\\t/", "s/a/b\\\nc/", "s/\\//|/g", "s/l/L/;s/o/0/", "s/./&&/3", "s/./&&/3g",
    "y/abc/xyz/", "y/abcdefghij/ABCDEFGHIJ/", "y/ /\\n/", "y/a\\/b/x|y/", "y,a\\,b,x.y,",
    "2p", "2,4p", "2,+2p", "$p", "1~2p", "2~3p", "0~2p", "2,~4p", "/e/p", "/e/!p", "/e/I p", "\\,e,p", "/e/,/o/p", "/a/,3p", "2,/e/p", "0,/e/p", "1,/e/p", "/e/,+1p", "$!p", "2,$p", "4,2p", "1,3!p", "/^$/,/^$/p", "2,3{p;p}", "/e/{s//E/;p}", "/e/s//X/",
    "2,3d", "/e/d", "/^$/d", "/e/,/o/d", "1!G;h;$!d", ":a;N;$!ba;s/\\n/ /g", "$!N;P;D", "$!N;s/\\n/ /", "N;N;s/\\n/,/g", "n;d", "n;n;s/./X/", "N;P;D", "G", "G;G", "x;G", "h;G", "H;x", "H;$!d;x", "1h;1!H;$!d;x", "x;$!d;G",
    "1i\\  ind", "2i hello", "$a end", "1a\\\ntwo\\\nlines", "a x", "i x", "/e/a found", "/e/i found", "2c changed", "2,3c changed", "2,3!c changed", "$!N;c X", "/e/c X", "c\\\nmulti\\\nline", "a foo\\\\bar", "a foo\\.bar",
    "-n", "-n p", "-n 2p", "-n $=", "-n /e/=", "-n 2,4=", "-n /e/{p;q}", "-n 2{p;q}", "3q;p", "/e/q", "/e/Q", "$!{p}", "2{N;N;s/\\n/+/g}", "/e/{N;s/\\n/+/}", "/a/{x;p;x}",
    ":a;s/^\\(\\s*\\)x/\\1y/;ta", "s/a/b/;ta;s/$/ no/;:a", "s/a/b/;Ta;s/$/ yes/;:a", "/e/b;s/^/! /", "/e/bend;s/^/! /;:end", "b;p", "ba;p;:a", "s/o/0/;t;s/$/./", "/x/!b;s/x/y/",
    "{p}", "{p;p}", "{;p;}", "p;p", "p ; p", "  p", "p # comment", "# only comment", "p;# c\np", "1{p}", "1,2{p}", "1!{p}", "{{p}}", "2{p;{p}}", "/e/{/o/p}", "$!{$!p}",
]

BAD_SCRIPTS = [
    "{", "}", "p}", "s/a/b", "s/a", "s/a/b/x", "s/a/b/gg", "s/a/b/pp", "s/a/b/0", "s/a/b/ q", "y/abc/xy/", "y/abc/xyz", "k", "bfoo", ":", "a", "0p", "0,5p", "1,p", ",3p", "1~p", "q 5 6", "1,2q", "2!!p", "s/\\(a\\)/\\2/", "s//x/", "/x/I I p",
    "w out", "r f", "R f", "W f", "e", "F", "l", "L", "z", "v", "s/a/b/w out", "s/a/b/e", "s/a/b/m", "s/a/b/M", "/a/M p", "1,~2p", "1,3~2p", "s/\\x41/b/", "s/a/\\x41/", "y/\\x41/b/", "s/a/\\cA/", "#n", "#n\np", "s/(a|b)/\\1/", "s/a\\|b/[&]/;s/\\(c\\)\\|d/\\1/", "N;ta;:a",
    "s/\\(a*\\)*/\\1/", "s/\\(a\\|b\\)/\\1/", "s/a\\?\\(b\\)/\\1/", "s.a\\.b.X.", "s|a\\|b|X|", "a\\", "s/a/b/;s/b/c/}", "y/é/e/",
]

STDINS = [b"", b"\n", b"a", b"a\n", b"hello world\nfoo bar\n\nbaz qux\nhello again\nfoo\n", b"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n", b"no trailing newline\nlast", b"x\n\n\nx\n\n", b"aaa bbb aaa\nabcabc\n  indented\t tab\n", b"a.b*c[d]e\\f/g\n", b"The Quick Brown fox\nthe lazy dog\n"]


def cases(fx):
    import os
    files = [f for f in FILES if os.path.exists(os.path.join(fx, f))]
    for sc in SCRIPTS:
        if sc.startswith("-n"):
            parts = sc.split(" ", 1)
            args = ["-n"] + ([parts[1]] if len(parts) > 1 else ["p"])
        else:
            args = [sc]
        for s in STDINS:
            yield Case(["sed"] + args, stdin=s)
        for f in ["lines5", "nonl", "words", "empty", "g1", "gnonl", "blank", "lines100", "nofile", "dir", "crlf", "onenonl"]:
            yield Case(["sed"] + args + [f])
    for sc in [x for x in SCRIPTS if not x.startswith("-n")]:
        for f in ["words", "lines5", "dups"]:
            yield Case(["sed", "-n", sc, f])
            yield Case(["sed", "-E", sc, f])
    for f in files:
        yield Case(["sed", "s/o/0/g", f])
        yield Case(["sed", "-n", "2,4p", f])
        yield Case(["sed", "-n", "$p", f])
        yield Case(["sed", "5q", f])
        yield Case(["sed", "-n", "/a/p", f])
        yield Case(["sed", "-e", "s/a/b/", "-e", "s/b/c/", f])
        yield Case(["sed", "--expression=s/a/b/", f])
        yield Case(["sed", "-ne", "2p", f])
        yield Case(["sed", "-n", "-e", "1p", "-e", "$p", f])
        yield Case(["sed", "--quiet", "1p", f])
        yield Case(["sed", "--silent", "1p", f])
    for a, b in itertools.product(["lines5", "nonl", "empty", "nofile", "onenonl", "dir", "words"], repeat=2):
        yield Case(["sed", "-n", "$p", a, b])
        yield Case(["sed", "p", a, b])
        yield Case(["sed", "=", a, b])
        yield Case(["sed", "N;P;D", a, b])
        yield Case(["sed", "$!d", a, b])
        yield Case(["sed", "-n", "2,4p", a, b])
        yield Case(["sed", "1~3d", a, b])
    yield Case(["sed", "p", "lines5", "-"], stdin=b"x\ny\n")
    yield Case(["sed", "-n", "$p", "-", "lines5"], stdin=b"x\ny")
    yield Case(["sed", "-n", "$p", "lines5", "-"], stdin=b"")
    yield Case(["sed", "-n", "p", "--", "lines5"])
    yield Case(["sed", "-E", "s/(a+)(b+)/\\2\\1/g"], stdin=b"aabbb ab aaabb\n")
    yield Case(["sed", "-E", "s/^(.)(.*)$/\\2\\1/"], stdin=b"hello\nworld\n")
    yield Case(["sed", "-E", "s/[0-9]+/<&>/g"], stdin=b"a1 b22 c333\n")
    yield Case(["sed", "-E", "s/(foo|bar)+/X/g"], stdin=b"foobarfoo bar baz\n")
    yield Case(["sed", "-E", "s/a{2,3}/X/g"], stdin=b"a aa aaa aaaa\n")
    yield Case(["sed", "-E", "s/a?b/X/g"], stdin=b"ab b aab\n")
    yield Case(["sed", "-E", "/^(a|b)/p"], stdin=b"a\nb\nc\n")
    yield Case(["sed", "-r", "s/(.)(.)/\\2\\1/g"], stdin=b"abcdef\n")
    yield Case(["sed", "-n", "-E", "/^[a-c]+$/p"], stdin=b"abc\nabd\ncab\n")
    yield Case(["sed", "-E", "s/(x)?y/[\\1]/g"], stdin=b"xy y\n")
    big = b"".join(b"Line %d of some Text, with Punctuation!\n" % i for i in range(20000))
    for sc in ["s/e/E/g", "-n 5,15p", "$d", "/9999/!d", "s/\\([0-9]*\\) of/\\1:/", "y/abc/ABC/", "10q", "$!N;P;D", "n;d", "-n $p", "1!G;h;$!d"]:
        parts = sc.split(" ", 1) if sc.startswith("-n") else [sc]
        args = ["-n", parts[1]] if sc.startswith("-n") else [sc]
        yield Case(["sed"] + args, stdin=big)
    for bad in BAD_SCRIPTS:
        yield Case(["sed", bad], stdin=b"abc\n", unsupported=True)
    for bad in [["-i", "p"], ["-z", "p"], ["-s", "p"], ["-f", "x"], ["--posix", "p"], ["-u", "p"], ["--debug", "p"], ["-l", "5", "p"], ["--help"], ["--version"], ["-x", "p"], ["-b", "p"], ["--follow-symlinks", "p"]]:
        yield Case(["sed"] + bad, stdin=b"abc\n", unsupported=True)

import itertools, os, random
from harness import Case

SETS = ["a", "abc", "a-z", "A-Z", "a-zA-Z", "0-9", "a-c0-3", "[:lower:]", "[:upper:]", "[:alpha:]", "[:digit:]", "[:alnum:]", "[:space:]", "[:blank:]", "[:punct:]", "[:cntrl:]", "[:print:]", "[:graph:]", "[:xdigit:]", "\\n", "\\t", "\\r", "\\\\", "\\012", "\\0", "\\377", " ", "-", "a-", "-a", "a\\-c", "[", "[a", "a]", "[a]", "x[", "[=a=]", "[=a=]b", "abca", "aab", "\\.", "[:lower:][:digit:]", "a-c[:digit:]x", "ab-d", "!-/", "\\000-\\037", "[x*]", "[x*3]", "[x*3]y", "ab[x*]", "[-]", "\\[", "[\\]]", "[a-c]", ".", "*", "%", "\\a\\b\\f\\v"]
INPUTS = [b"", b"\n", b"hello world\n", b"Hello, World! 123 abc ABC xyz\n\ttab\r\n", b"aaabbbcccdddeee   ...---___\n\n\n", bytes(range(256)), bytes(range(256)) * 300, b"a[b]c-d\\e.f*g\n", b"The Quick  Brown\tFox\n  jumps\n\n"]


def cases(fx):
    rnd = random.Random(7)
    for s1 in SETS:
        for inp in INPUTS:
            yield Case(["tr", "-d", s1], stdin=inp)
            yield Case(["tr", "-s", s1], stdin=inp)
            yield Case(["tr", "-c", "-d", s1], stdin=inp)
            yield Case(["tr", "-cs", s1], stdin=inp)
    for s1 in SETS:
        for s2 in SETS:
            inp = rnd.choice(INPUTS[2:])
            yield Case(["tr", s1, s2], stdin=inp)
            if rnd.random() < 0.5:
                yield Case(["tr", "-s", s1, s2], stdin=inp)
                yield Case(["tr", "-ds", s1, s2], stdin=inp)
                yield Case(["tr", "-c", s1, s2], stdin=inp)
                yield Case(["tr", "-cs", s1, s2], stdin=inp)
                yield Case(["tr", "-t", s1, s2], stdin=inp)
                yield Case(["tr", "-C", s1, s2], stdin=inp)
    for inp in INPUTS:
        yield Case(["tr", "a-z", "A-Z"], stdin=inp)
        yield Case(["tr", "[:lower:]", "[:upper:]"], stdin=inp)
        yield Case(["tr", "[:upper:]", "[:lower:]"], stdin=inp)
        yield Case(["tr", "-cs", "a-zA-Z", "\\n"], stdin=inp)
        yield Case(["tr", "-cs", "[:alnum:]", "\\n"], stdin=inp)
        yield Case(["tr", "-d", "\\r"], stdin=inp)
        yield Case(["tr", "-d", "\\n"], stdin=inp)
        yield Case(["tr", "\\n", " "], stdin=inp)
        yield Case(["tr", "-s", " "], stdin=inp)
        yield Case(["tr", "-s", "\\n"], stdin=inp)
        yield Case(["tr", "-d", "[:space:]"], stdin=inp)
        yield Case(["tr", "--delete", "--complement", "0-9"], stdin=inp)
        yield Case(["tr", "--squeeze-repeats", "--truncate-set1", "abc", "x"], stdin=inp)
        yield Case(["tr", " ", "\\t"], stdin=inp)
        yield Case(["tr", "'", '"'], stdin=inp)
        yield Case(["tr", "--", "-a", "xy"], stdin=inp)
        yield Case(["tr", "\\000", "x"], stdin=inp)
    big = b"".join(b"Line %d of some Text, with Punctuation!\n" % i for i in range(20000))
    for a in [["a-z", "A-Z"], ["-d", "e"], ["-s", "l"], ["-cs", "a-z", "\\n"], ["-d", "[:digit:]"]]:
        yield Case(["tr"] + a, stdin=big)
    for bad in [[], ["a"], ["-d"], ["-d", "a", "b"], ["a", "b", "c"], ["z-a", "x"], ["[:foo:]", "x"], ["a", "[:upper:]"], ["[:upper:]", "[:digit:]"], ["a", ""], ["\\", "x"], ["a", "b\\"], ["-t", "-d", "a"], ["-x", "a"]]:
        yield Case(["tr"] + bad, stdin=b"abc", unsupported=True)

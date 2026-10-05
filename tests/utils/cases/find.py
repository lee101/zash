from harness import Case
import lsfix

PATHS = [["lsx"], ["rtree"], ["dir"], ["."], [], ["nofile"], ["rtree/lnkdir"], ["rtree/lnkdir/"], ["lsx/link_file"], ["lsx/", "dir/"], ["lsx/sub/"], ["lsx//sub"], ["lsx/a.txt"], ["emptydir", "lsx/empty"], ["/dev/null"], ["lsx/many", "nofile", "lsx/sub"]]

EXPRS = [
    [], ["-print"], ["-print0"], ["-name", "*.txt"], ["-name", "a*"], ["-iname", "A*"], ["-iname", "*TXT"], ["-name", "sub"], ["-name", "."], ["-name", "*"], ["-name", "[ab]*"], ["-name", "?"], ["-name", "d?"],
    ["-type", "f"], ["-type", "d"], ["-type", "l"], ["-type", "p"], ["-type", "s"], ["-type", "c"], ["-type", "b"], ["-type", "f", "-name", "*.txt"], ["-name", "*.txt", "-type", "f"],
    ["-path", "*sub*"], ["-path", "*/deep/*"], ["-ipath", "*SUB*"], ["-wholename", "lsx/sub"], ["-path", "lsx/sub/*"],
    ["-not", "-name", "*.txt"], ["!", "-type", "d"], ["!", "-name", "a*", "-type", "f"],
    ["-name", "a*", "-o", "-name", "B*"], ["-name", "a*", "-or", "-name", "B*", "-print"], ["-name", "a*", "-a", "-type", "f"], ["-name", "a*", "-and", "-type", "f"],
    ["(", "-name", "a*", "-o", "-name", "B*", ")", "-type", "f"], ["(", "-name", "a*", "-o", "-name", "B*", ")", "-o", "-type", "d"],
    ["-type", "f", "(", "-name", "*.txt", "-o", "-name", "*.log", ")"], ["!", "(", "-name", "a*", "-o", "-type", "d", ")"],
    ["-empty"], ["-type", "f", "-empty"], ["-type", "d", "-empty"], ["-empty", "-print"], ["-size", "0"], ["-size", "0c"], ["-size", "+1k"], ["-size", "-1k"], ["-size", "1k"], ["-size", "+1M"], ["-size", "10c"], ["-size", "-2"],
    ["-size", "+1G"], ["-size", "1w"], ["-size", "+100k", "-type", "f"],
    ["-maxdepth", "0"], ["-maxdepth", "1"], ["-maxdepth", "2"], ["-mindepth", "1"], ["-mindepth", "2"], ["-mindepth", "1", "-maxdepth", "1"], ["-maxdepth", "1", "-type", "f"], ["-mindepth", "1", "-maxdepth", "2", "-name", "*.txt"],
    ["-name", "sub", "-prune", "-o", "-print"], ["-name", "deep", "-prune"], ["-type", "d", "-name", "sub", "-prune", "-o", "-type", "f", "-print"], ["-prune"], ["-name", "d", "-prune", "-o", "-name", "*.txt", "-print"],
    ["-depth"], ["-depth", "-name", "*.txt"], ["-depth", "-type", "d"], ["-depth", "-maxdepth", "2"],
    ["-newer", "lsx/a.txt"], ["-newer", "lsx/B.txt", "-type", "f"], ["-newer", "nofile"],
    ["-true"], ["-false"], ["-true", "-print"], ["-false", "-o", "-print"], ["-print", "-print"], ["-name", "*.txt", "-print", "-name", "a*", "-print"],
    ["-type", "f", "-print0"], ["-name", "*.txt", "-print0", "-print"],
]

UNSUP = [
    ["-exec", "echo", "{}", ";"], ["-delete"], ["-ls"], ["-printf", "%p\n"], ["-L"], ["-H"], ["-follow"], ["-mtime", "1"], ["-perm", "644"], ["-user", "lee"], ["-regex", ".*"], ["-xdev"], ["-mount"],
    ["-name", "a/b"], ["-type", "f,d"], ["-type", "x"], ["-name", "a", "-maxdepth", "1"], ["-name", "a", "-mindepth", "1"], ["-name"], ["-name", "a", "-o"], ["(", "-name", "a"], ["-name", "a", ")"], ["-maxdepth", "x"], ["-maxdepth", "-1"],
    ["-prune", "-depth"], ["-quit"], ["-ok", "echo", "{}", ";"], [","], ["-name", "a", ",", "-name", "b"], ["-size", "k"], ["-size", "+"], ["-bogus"], ["-noleaf"], ["-name", "a", "-depth"],
]


def cases(fx):
    lsfix.build(fx)
    for p in PATHS:
        for e in EXPRS:
            yield Case(["find"] + p + e)
    for e in UNSUP:
        yield Case(["find", "lsx"] + e, unsupported=True)
    yield Case(["find", "lsx", "-name", "?"], env={"LC_ALL": "en_US.UTF-8"}, unsupported=True)
    yield Case(["find", "lsx", "-name", "[a]*"], env={"LC_ALL": "C.UTF-8"}, unsupported=True)
    yield Case(["find", "lsx", "-name", "a*"], env={"LC_ALL": "en_US.UTF-8"})
    yield Case(["find", "lsx", "-name", "a*"], env={"LC_ALL": "C.UTF-8"})
    yield Case(["find", "lsx", "-iname", "é*"], env={"LC_ALL": "en_US.UTF-8"}, unsupported=True)
    yield Case(["find", "nofile"], env={"LC_ALL": "C.UTF-8"})
    yield Case(["find", "no'file"], unsupported=True)
    yield Case(["find", "no\\file"], unsupported=True)
    yield Case(["find", ""])
    yield Case(["find", "-P", "lsx", "-type", "f"])
    yield Case(["find", "-P"])
    yield Case(["find", "lsx", "-P"], unsupported=True)

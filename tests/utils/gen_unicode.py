import subprocess, sys, os, unicodedata

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "src", "utils", "unicode_sets.zig")
GENV = {"LC_ALL": "C.UTF-8", "PATH": "/usr/bin"}
cps = [c for c in range(1, 0x110000) if not (0xD800 <= c <= 0xDFFF) and c != 10]
idx = {i + 1: c for i, c in enumerate(cps)}
path = "/tmp/zgen_allcp.txt"
open(path, "wb").write(b"".join(chr(c).encode("utf-8") + b"\n" for c in cps))


def probe(cmd, env, file=path, index=idx):
    r = subprocess.run(cmd + [file], capture_output=True, env=env)
    s = set()
    for l in r.stdout.split(b"\n"):
        if l:
            s.add(index[int(l.split(b":", 1)[0])])
    return s


def ranges(s):
    out = []
    for c in sorted(s):
        if out and out[-1][1] == c - 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return out


def emit(name, s):
    rs = ranges(s)
    return "pub const %s = [_][2]u32{\n%s\n};\n" % (name, "\n".join("    .{ 0x%x, 0x%x }," % (a, b) for a, b in rs))


rg = ["/usr/bin/rg", "-n", "--no-heading", "-j1"]
gr = ["/usr/bin/grep", "-n"]
sets = {}
sets["rust_word"] = probe(rg + [r"^\w$"], {"PATH": "/usr/bin"})
sets["rust_digit"] = probe(rg + [r"^\d$"], {"PATH": "/usr/bin"})
sets["rust_space"] = probe(rg + [r"^\s$"], {"PATH": "/usr/bin"})
for cls in ["alpha", "alnum", "upper", "lower", "punct", "space", "print", "graph", "cntrl", "blank", "digit", "xdigit"]:
    sets["glibc_" + cls] = probe(gr + ["^[[:%s:]]$" % cls], GENV)
sets["glibc_word"] = probe(gr + [r"^\w$"], GENV)
sets["glibc_space_esc"] = probe(gr + [r"^\s$"], GENV)
assert sets["glibc_space_esc"] == sets["glibc_space"], "space mismatch"
del sets["glibc_space_esc"]
assert sets["glibc_word"] == sets["glibc_alnum"] | {ord("_")}, "word mismatch"

cand = set()
for c in cps:
    ch = chr(c)
    for f in (ch.lower, ch.upper, ch.title, ch.casefold):
        r = f()
        if len(r) == 1 and r != ch:
            cand.add(c)
            cand.add(ord(r))
cand = sorted(cand)
cpath = "/tmp/zgen_cand.txt"
open(cpath, "wb").write(b"".join(chr(c).encode("utf-8") + b"\n" for c in cand))
cidx = {i + 1: c for i, c in enumerate(cand)}


def folds(cmd, env):
    res = {}
    for x in cand:
        xs = chr(x).encode("utf-8")
        r = subprocess.run(cmd + [xs, cpath], capture_output=True, env=env)
        s = set()
        for l in r.stdout.split(b"\n"):
            if l:
                s.add(cidx[int(l.split(b":", 1)[0])])
        res[x] = s
    return res


def classes(res):
    parent = {}

    def find(a):
        while parent.setdefault(a, a) != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for x, s in res.items():
        for y in s:
            ra, rb = find(x), find(y)
            if ra != rb:
                parent[ra] = rb
    groups = {}
    for x in list(parent):
        groups.setdefault(find(x), set()).add(x)
    return [sorted(g) for g in groups.values() if len(g) > 1]


rfold = classes(folds(["/usr/bin/rg", "-n", "--no-heading", "-i", "-x", "-F", "-e"], {"PATH": "/usr/bin"}))
gfold = classes(folds(["/usr/bin/grep", "-n", "-i", "-x", "-F", "-e"], GENV))
rfold.sort()
gfold.sort()


def emit_classes(name, cls):
    flat = []
    for g in cls:
        flat.extend(g)
        flat.append(0)
    lines = []
    for i in range(0, len(flat), 12):
        lines.append("    " + ", ".join("0x%x" % v for v in flat[i:i + 12]) + ",")
    return "pub const %s = [_]u32{\n%s\n};\n" % (name, "\n".join(lines))


with open(OUT, "w") as f:
    for k in sorted(sets):
        f.write(emit(k + "_ranges", sets[k]))
    f.write(emit_classes("rust_fold", rfold))
    f.write(emit_classes("glibc_fold", gfold))
print("rust word", len(sets["rust_word"]), "glibc alpha", len(sets["glibc_alpha"]), "classes", len(rfold), len(gfold))

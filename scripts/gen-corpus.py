#!/usr/bin/env python3
"""Regenerates bench/corpus/*.sh: synthetic commands modeled on what coding agents run.
Every entry is invented from templates; none is a real recorded command. Deterministic.
usage: scripts/gen-corpus.py [outdir] [fixture]
With a fixture (default bench/.fixture, built by bench/fixture/gen.py) entries that print nothing or are
nondeterministic under real bash are dropped.
"""
import os, random, subprocess, sys, glob

HERE = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "bench", "corpus")
fixture = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "..", "bench", ".fixture")
rng = random.Random(42)
entries = []  # (category, requires, cmd)
seen = set()

def add(cat, cmd, req=()):
    cmd = cmd.strip("\n")
    if cmd in seen: return
    seen.add(cmd)
    entries.append((cat, tuple(req), cmd))

def pick(xs, k):
    xs = list(xs)
    rng.shuffle(xs)
    return xs[:k]

PATS = ["TODO", "FIXME", "HACK", "NOTE:", "func ", "def ", "class ", "import ", "return", "Errorf", "throw new", "Result<", "IllegalArgument",
        "handle_request", "handleRequest", "HandleRequest", "parse_config", "ValueError", "unittest", "fetch_user", "render_", "Promise<", "#include"]
DIRS = ["src", "src/go", "src/py", "src/js", "src/ts", "src/rs", "src/c", "src/java", "tests", "docs", "config", "scripts", "src/go/pkg03", "src/py/mod05", "src/ts/svc01"]
SMALLDIRS = ["src/go/pkg03", "src/py/mod05", "src/js/comp02", "src/ts/svc01", "src/rs/crate03/src", "src/c/lib02", "docs/guide00", "scripts/tools00", "tests/unit00", "config/cfg00", "data/small", "src/java/com/example/pkg02"]
EXTS = ["go", "py", "js", "ts", "rs", "c", "h", "java", "md", "sh", "json", "yaml"]
FILES = ["src/go/pkg03/f0080.go", "src/go/pkg10/f0260.go", "src/py/mod05/f0150.py", "src/py/mod12/f0370.py", "src/js/comp02/f0040.js", "src/js/comp11/f0230.js",
         "src/ts/svc01/f0020.ts", "src/ts/svc07/f0145.ts", "src/rs/crate03/src/f0065.rs", "src/c/lib02/f0045.c", "src/c/lib04/f0085.c", "src/java/com/example/pkg02/f0025.java",
         "docs/guide00/f0007.md", "docs/guide00/f0042.md", "scripts/tools00/f0010.sh", "tests/unit00/f0033.py", "README.md", "Makefile", "package.json", "data/kv.env"]
DATA = ["data/words.txt", "data/numbers.txt", "data/spaces.txt", "data/users.csv", "data/users.tsv", "data/paths.txt", "data/access.log", "logs/app.log"]
N = [3, 5, 10, 15, 20, 30, 50, 100]

# ---------------- search ----------------
S = "search"
for p in PATS[:12]:
    for d in pick(DIRS, 3):
        add(S, f"rg -n --sort path '{p}' {d} | head -{rng.choice(N)}")
for p in pick(PATS, 10):
    add(S, f"rg -l --sort path '{p}' src | head -{rng.choice(N)}")
    add(S, f"rg -c --sort path '{p}' {rng.choice(SMALLDIRS)} | head -{rng.choice(N)}")
    add(S, f"rg -n '{p}' {rng.choice(FILES[:12])} | head -{rng.choice(N)}")
    add(S, f"rg -n --sort path -g '*.{rng.choice(EXTS[:6])}' '{p}' | head -{rng.choice(N)}")
    add(S, f"rg --sort path '{p}' src | wc -l")
    add(S, f"rg -i --sort path '{p}' docs | tail -{rng.choice(N)}")
for d in pick(SMALLDIRS, 6):
    add(S, f"rg --files {d} | sort | head -{rng.choice(N)}")
    add(S, f"rg --files {d} | wc -l")
add(S, "rg --files -g '*.go' src | sort | head -20")
add(S, "rg -n --sort path 'func \\w+\\(' src/go/pkg03 | head -30")
add(S, "rg -n --sort path 'TODO|FIXME' src/py/mod05 | head -30")
add(S, "rg -w 'x' src/go/pkg00/f0000.go | head")
add(S, "rg -n 'nonexistent_symbol_xyz' src | head -5")
add(S, "rg -n 'nonexistent_symbol_xyz' src; echo $?")
for p in PATS[:14]:
    for d in pick(DIRS, 2):
        add(S, f"grep -rn '{p}' {d} | cut -d: -f1 | sort -u | head -{rng.choice(N)}")
for p in pick(PATS, 14):
    d = rng.choice(DIRS)
    e = rng.choice(EXTS[:6])
    add(S, f"grep -rn '{p}' {d} --include='*.{e}' | head -{rng.choice(N)}")
    add(S, f"grep -rl '{p}' {d} | wc -l")
    add(S, f"grep -rn '{p}' {d} | wc -l")
    add(S, f"grep -c '{p}' {rng.choice(FILES[:14])}")
    add(S, f"grep -n '{p}' {rng.choice(FILES[:14])} | head -{rng.choice(N)}")
    add(S, f"grep -rIn --exclude-dir=node_modules --exclude-dir=.git '{p}' {d} | head -{rng.choice(N)}")
for f in pick(FILES, 8):
    add(S, f"grep -E 'TODO|FIXME|HACK' {f} | head")
    add(S, f"grep -v '^$' {f} | head -{rng.choice(N)}")
    add(S, f"grep -in 'error' {f} | head -5")
    add(S, f"grep -m 2 -n return {f}")
add(S, "grep -rn foo . | cut -d: -f1 | sort -u | head")
add(S, "grep -rn 'x' src/go/pkg00 | head -3")
add(S, "grep -rnw 'int' src/c/lib00 | head -10")
add(S, "grep -n 'zzzzz' README.md; echo \"status $?\"")
add(S, "grep -q TODO README.md && echo found")
for e in EXTS[:8]:
    d = rng.choice(["src", ".", "src", "docs", "tests"])
    add(S, f"find {d} -name '*.{e}' | head -{rng.choice(N)}")
    add(S, f"find {d} -type f -name '*.{e}' | wc -l")
    add(S, f"find src -name '*.{e}' | xargs wc -l | tail -1")
    add(S, f"find src -name '*.{e}' | xargs grep -l 'TODO' | wc -l")
    add(S, f"find src -name '*.{e}' -type f | sort | tail -3")
add(S, "find . -name '*.go' | xargs wc -l | tail -1")
add(S, "find . -path ./node_modules -prune -o -path ./.git -prune -o -name '*.py' -print | wc -l")
add(S, "find . -type d -maxdepth 2 -not -path './.git*' | sort | head -20")
add(S, "find src -maxdepth 1 -type d | sort")
add(S, "find . -name node_modules -prune -o -type f -name '*.js' -print | head -5")
add(S, "find node_modules -name 'package.json' | wc -l")
add(S, "find . -empty -type f -not -path './.git/*' | head")
add(S, "find src -type f -size +4k | wc -l")
add(S, "find src/go -name '*.go' -exec grep -l Errorf {} + | head -3")
add(S, "find data -type f | sort")
add(S, "find . -maxdepth 1 -type f | sort | head -20")
add(S, "fd_missing() { command -v fd >/dev/null; }; fd_missing || find . -maxdepth 1 -name '*.md' | sort")
for p in pick(PATS, 4):
    add(S, f"git grep -n '{p}' | head -{rng.choice(N)}")
    add(S, f"git grep -c '{p}' -- src/go | head -5")

# ---------------- text pipelines ----------------
T = "text-pipeline"
for f in pick(DATA[:7], 5):
    for n in (10, 20, 50):
        add(T, f"head -n {n} {f}")
        add(T, f"tail -n {n} {f}")
        add(T, f"cat {f} | head -{n}")
        add(T, f"cat {f} | tail -{n}")
for f in DATA:
    add(T, f"wc -l {f}")
    add(T, f"wc -c < {f}")
    add(T, f"wc -w {f}")
    add(T, f"cat {f} | wc -l")
    add(T, f"head -c 200 {f}")
    add(T, f"tail -n +5 {f} | head -3")
for f in pick(FILES, 12):
    a = rng.randint(1, 60)
    b = a + rng.choice([5, 10, 20, 40])
    add(T, f"sed -n '{a},{b}p' {f}")
    add(T, f"sed -n '{a}p' {f}")
    add(T, f"sed 's/return/RET/g' {f} | head -{rng.choice(N)}")
    add(T, f"sed -n '/func\\|def \\|class /p' {f} | head")
    add(T, f"sed '/^$/d' {f} | head -{rng.choice(N)}")
    add(T, f"sed -e 's/^[ \\t]*//' {f} | head -5")
    add(T, f"cat {f} | tr -s ' ' | cut -c1-40 | head -{rng.choice(N)}")
    add(T, f"head -{rng.choice(N)} {f} | tail -5")
    add(T, f"tail -n 30 {f} | head -n 10")
    add(T, f"cat -n {f} | sed -n '5,15p'")
    add(T, f"nl -ba {f} | head -5")
    add(T, f"tr 'a-z' 'A-Z' < {f} | head -5")
    add(T, f"tr -d '\\t' < {f} | wc -c")
for _ in range(6):
    add(T, f"sed -n '{rng.randint(100,800)},{rng.randint(801,900)}p' data/words.txt | head -{rng.choice(N)}")
add(T, "cat data/spaces.txt | tr -s ' ' | cut -d' ' -f1-3 | head -20")
add(T, "cat data/spaces.txt | tr -s ' ' | cut -d' ' -f2- | head -20")
add(T, "cat data/users.tsv | cut -f2- | head -20")
add(T, "cut -f2,4 data/users.tsv | sort | uniq -c | sort -rn | head")
add(T, "cut -f4 data/users.tsv | sort | uniq -c | sort -rn")
add(T, "cut -d, -f5 data/users.csv | sort | uniq -c | sort -rn | head")
add(T, "cut -d, -f2,3 data/users.csv | head -10")
add(T, "cut -d, -f4 data/users.csv | sort -n | tail -3")
add(T, "cut -d, -f1 data/users.csv | tail -n +2 | sort -n | tail -1")
add(T, "tail -n +2 data/users.csv | cut -d, -f5 | sort | uniq -c | sort -rn | head -3")
add(T, "sort data/words.txt | uniq -c | sort -rn | head -10")
add(T, "sort -u data/words.txt | wc -l")
add(T, "sort data/words.txt | uniq -d | head -5")
add(T, "sort -n data/numbers.txt | head -3")
add(T, "sort -rn data/numbers.txt | head -3")
add(T, "sort -n data/numbers.txt | tail -1")
add(T, "sort -t, -k4 -n data/users.csv | tail -2")
add(T, "sort -k2 data/spaces.txt | head -3")
add(T, "sort -r data/words.txt | head -3")
add(T, "sort -u data/paths.txt | head -5")
add(T, "sort data/paths.txt | uniq | wc -l")
add(T, "cut -d/ -f3 data/paths.txt | sort | uniq -c | sort -rn | head")
add(T, "cut -d/ -f4 data/paths.txt | sort | uniq -c | sort -rn | head -5")
add(T, "rev data/paths.txt | cut -d. -f1 | rev | head -3")
add(T, "sed 's/.*\\.//' data/paths.txt | sort | uniq -c")
add(T, "grep -o '[a-z]*$' data/paths.txt | head -3")
add(T, "awk -F, '{print $5}' data/users.csv | sort | uniq -c | sort -rn | head -3")
add(T, "awk '{print $1}' data/access.log | sort | uniq -c | sort -rn | head -5")
add(T, "awk '{print $9}' data/access.log | sort | uniq -c")
add(T, "awk '{s+=$1} END{print s}' data/numbers.txt")
add(T, "awk 'NR%1000==0' data/words.txt | head -5")
add(T, "awk -F'\\t' '$3>990 {print $2}' data/users.tsv | head -5")
add(T, "cut -d' ' -f1 data/access.log | sort | uniq -c | sort -rn | head -5")
add(T, "grep ' 500 ' data/access.log | wc -l")
add(T, "grep -c ' 404 ' data/access.log")
add(T, "grep '\"POST' data/access.log | cut -d'\"' -f2 | sort | uniq -c | sort -rn | head -3")
add(T, "cut -d'\"' -f2 data/access.log | cut -d' ' -f2 | sort | uniq -c | sort -rn | head")
add(T, "tail -n 200 logs/app.log | grep ERROR")
add(T, "tail -n 200 logs/app.log | grep -c WARN")
add(T, "tail -n 1000 logs/app.log | cut -d' ' -f2 | sort | uniq -c")
add(T, "grep ERROR logs/app.log | head -5")
add(T, "grep ERROR logs/app.log | wc -l")
add(T, "grep -c ERROR logs/app.log")
add(T, "grep ERROR logs/app.log | cut -d' ' -f4 | sort | uniq -c | sort -rn | head")
add(T, "grep ERROR logs/app.log | sed 's/.*ERROR *//' | cut -d' ' -f2- | cut -c1-30 | sort | uniq -c | sort -rn | head -5")
add(T, "grep -E 'ERROR|WARN' logs/app.log | tail -5")
add(T, "grep -v INFO logs/app.log | head -10")
add(T, "grep timeout logs/app.log | tail -3")
add(T, "cut -d' ' -f2 logs/app.log | sort | uniq -c | sort -rn")
add(T, "cut -d' ' -f1 logs/app.log | cut -c12-13 | sort | uniq -c | head -5")
add(T, "head -1 logs/app.log; tail -1 logs/app.log")
add(T, "sed -n '1000,1010p' logs/app.log")
add(T, "sed -n '$p' logs/app.log")
add(T, "tac logs/app.log | head -3")
add(T, "grep -n ERROR logs/app.log | tail -2")
add(T, "grep -o 'status=[0-9]*' logs/app.log | sort | uniq -c")
add(T, "grep -o 'dur=[0-9]*' logs/app.log | cut -d= -f2 | sort -n | tail -3")
add(T, "grep -A1 'disk quota' logs/app.log | head -6")
add(T, "grep -B1 'unexpected EOF' logs/app.log | head -6")
add(T, "echo 'one two three' | tr ' ' '\\n' | sort | head -2")
add(T, "echo 'a,b,c' | tr ',' '\\n' | wc -l")
add(T, "echo hello world | head -1")
add(T, "echo 'hello world' | sed 's/world/there/'")
add(T, "echo 'Hello World' | tr 'A-Z' 'a-z'")
add(T, "echo '  padded  ' | sed 's/^ *//;s/ *$//'")
add(T, "echo 'key=value' | cut -d= -f2")
add(T, "echo \"$(printf 'x%.0s' 1 2 3 4 5)\" | wc -c")
add(T, "printf '%s\\n' c a b | sort")
add(T, "printf '%s\\n' c a b a | sort | uniq -c")
add(T, "printf 'a b\\nc d\\n' | cut -d' ' -f2")
add(T, "printf '%s\\n' one two three | paste -sd,")
add(T, "printf '%s\\n' x y z | xargs -n1 echo item")
add(T, "printf '3\\n1\\n2\\n' | sort -n | tail -1")
add(T, "seq 1 20 | tail -3")
add(T, "seq 1 1000 | wc -l")
add(T, "seq 1 100 | paste -sd+ | bc 2>/dev/null || echo nobc")
add(T, "ls src | xargs -I{} echo dir:{}")
add(T, "ls data/small | head -5 | xargs -n1 echo")
add(T, "cat data/words.txt | sort -u | head -5 | tr '\\n' ' '; echo")
add(T, "sort data/words.txt | uniq -c | sort -rn | head -3 | cut -c1-30")
add(T, "cat data/kv.env | cut -d= -f1 | head -5")
add(T, "cat data/kv.env | cut -d= -f2 | sort -n | tail -2")
add(T, "grep '_1' data/kv.env | head -3")
add(T, "sed -n 's/^\\(.*\\)=\\(.*\\)$/\\2 \\1/p' data/kv.env | head -3")
add(T, "tr -s ' ' < data/spaces.txt | head -2")
add(T, "tr -cd 'a-z\\n' < data/words.txt | head -3")
add(T, "fold -w 20 data/oneline.txt")
add(T, "expand data/oneline.txt")
add(T, "comm -12 <(sort data/words.txt | uniq | head -50) <(sort data/words.txt | uniq | head -30) | wc -l")
add(T, "diff <(head -5 data/words.txt) <(head -5 data/words.txt) && echo same")
add(T, "diff <(head -5 data/words.txt) <(sed -n '2,6p' data/words.txt) | head -3")
add(T, "md5sum data/oneline.txt | cut -d' ' -f1")
add(T, "sha1sum README.md | cut -c1-8")
add(T, "cat README.md | head -3 | tee $SCRATCH/o.txt | wc -l")
add(T, "python3 -c \"print(sum(range(100)))\"")
add(T, "python3 -c \"import json;print(len(json.load(open('config/cfg00/f0000.json'))))\"")
add(T, "python3 -c \"print(open('data/oneline.txt').read().upper().strip())\"")
add(T, "python3 -c \"import sys;print(len(sys.argv))\" a b c")
add(T, "python3 -c 'print(\"x\"*5)' | tr x y")
add(T, "cat config/cfg00/f0003.json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'")
add(T, "curl -s file://$PWD/data/oneline.txt")
add(T, "curl -s file://$PWD/data/words.txt | head -3")
add(T, "curl -s file://$PWD/data/words.txt | sort -u | wc -l")
add(T, "timeout 5 wc -l data/words.txt")
add(T, "timeout 5 grep -c TODO README.md")
add(T, "timeout 2 sleep 0.01; echo $?")
add(T, "sleep 0.01 && echo done")
add(T, "xargs -n1 echo < data/oneline.txt")
add(T, "cat data/oneline.txt | xargs echo got")
add(T, "yes | head -3")
add(T, "yes ok | head -n 20 | wc -l")
add(T, "stat -c %s README.md")
add(T, "wc -l $(git ls-files | head -100) | tail -1")
add(T, "cat $(ls data/small/*.txt | head -5) | wc -l")
add(T, "head -n 2 data/small/*.txt | head -12")
add(T, "tail -n 1 data/small/s0*.txt | head -12")
add(T, "cat data/small/*.txt | wc -l")
add(T, "cat data/small/*.txt | sort | uniq -c | sort -rn | head -3")
add(T, "cat data/small/s0[0-4].txt | cut -d' ' -f1 | sort -u | head -5")
add(T, "wc -l data/small/*.txt | tail -1")
add(T, "wc -l data/small/*.txt | sort -n | tail -3")
add(T, "head -qn1 data/small/s1*.txt | sort | head -3")
# big logs (need FIXTURE_BIG)
for lg, tag in (("logs/medium.log", "50m"), ("logs/huge.log", "500m")):
    r = [lg]
    add(T, f"head -n 5 {lg}", r)
    add(T, f"tail -n 5 {lg}", r)
    add(T, f"head -n 100000 {lg} | tail -n 3", r)
    add(T, f"grep -m 3 timeout {lg}", r)
    add(T, f"grep ERROR {lg} | head -3", r)
    add(T, f"wc -l {lg}", r)
    add(T, f"grep -c ERROR {lg}", r)
    add(T, f"sed -n '100000,100004p' {lg}", r)
    add(T, f"tail -n 1000 {lg} | cut -d' ' -f2 | sort | uniq -c", r)
    add(T, f"cut -d' ' -f2 {lg} | head -100000 | sort | uniq -c | sort -rn", r)
    add(T, f"cat {lg} | head -5", r)
    add(T, f"cat {lg} | wc -c", r)
    add(T, f"grep -c 'status=500' {lg}", r)
    add(T, f"tail -n 200 {lg} | grep -c ERROR", r)

# ---------------- fs-listing ----------------
F = "fs-listing"
for d in SMALLDIRS + ["src", "docs", ".", "data", "src/go", "logs", "config"]:
    add(F, f"ls -la {d} | head")
    add(F, f"ls {d} | head -{rng.choice(N)}")
    add(F, f"ls -1 {d} | wc -l")
for d in pick(SMALLDIRS, 8):
    add(F, f"ls -lh {d} | tail -3")
    add(F, f"ls -la {d} | tail -n +2 | head -4")
    add(F, f"ls -lS {d} | head -4")
    add(F, f"ls -lt {d} | head -4")
    add(F, f"ls -a {d} | head -3")
    add(F, f"cd {d} && ls | head -3")
    add(F, f"cd {d} && ls -la | tail -2")
    add(F, f"cd {d} && pwd")
    add(F, f"cd {d} && ls | wc -l")
    add(F, f"du -sh {d}")
    add(F, f"[ -d {d} ] && echo yes")
    add(F, f"test -d {d} && ls {d} | head -2 || echo no")
add(F, "ls -ld src/*/ | head")
add(F, "ls -d src/*/")
add(F, "ls *.md")
add(F, "ls -R docs | head -5")
add(F, "ls -R src/rs | head -10")
add(F, "ls -la")
add(F, "ls -A | head")
add(F, "ls -1 src/go | head -3")
add(F, "ls src/go/pkg0* | head -5")
add(F, "ls src/go/pkg0[0-2] | wc -l")
add(F, "ls -d */")
add(F, "ls /nonexistent_dir; echo $?")
add(F, "ls nonexistent_file 2>&1 | head -2")
add(F, "echo src/*/ | wc -w")
add(F, "echo *.md")
add(F, "echo data/small/s0?.txt | wc -w")
add(F, "echo {a,b,c}{1,2}")
add(F, "echo src/go/pkg0[0-4] | tr ' ' '\\n' | tail -2")
for f in pick(FILES, 12):
    add(F, f"[ -f {f} ] && echo yes")
    add(F, f"[ -f {f} ] && echo yes || echo no")
    add(F, f"test -s {f} && echo nonempty")
    add(F, f"[ -r {f} ] && [ -w {f} ] && echo rw")
    add(F, f"stat -c '%s %n' {f}")
    add(F, f"wc -c {f}")
    add(F, f"basename {f}")
    add(F, f"dirname {f}")
    add(F, f"file_size=$(wc -c < {f}); echo $file_size")
add(F, "[ -f nonexistent ] && echo yes")
add(F, "[ -f nonexistent ] || echo no")
add(F, "test -e .git && echo repo")
add(F, "[ -d node_modules ] && ls node_modules | wc -l")
add(F, "ls node_modules | head -3")
add(F, "ls node_modules | wc -l")
add(F, "cd src && ls")
add(F, "cd /tmp && cd - >/dev/null && pwd")
add(F, "pwd")
add(F, "cd src/go && pwd && cd .. && pwd")
add(F, "realpath src/go/../py")
add(F, "readlink -f docs/..")
add(F, "ls -la .gitignore && cat .gitignore")
add(F, "cat .gitignore | head -3")
add(F, "ls -la | grep -c '^d'")
add(F, "ls -l | awk '{print $NF}' | head -5")
add(F, "ls -l data | wc -l")
add(F, "ls data | sort -r | head -3")
add(F, "mkdir -p $SCRATCH/x/y && touch $SCRATCH/x/y/z && ls $SCRATCH/x/y")
add(F, "mkdir -p $SCRATCH/t && cd $SCRATCH/t && touch a b c && ls | wc -l")
add(F, "cp README.md $SCRATCH/r.md && wc -l $SCRATCH/r.md")
add(F, "cp -r data/small $SCRATCH/small && ls $SCRATCH/small | wc -l")
add(F, "rm -rf $SCRATCH/gone && mkdir $SCRATCH/gone && ls -a $SCRATCH/gone")
add(F, "mv $SCRATCH/none $SCRATCH/none2 2>&1 | head -1")
add(F, "ln -sf $PWD/README.md $SCRATCH/lnk && readlink $SCRATCH/lnk | wc -c")
add(F, "touch $SCRATCH/f && [ -e $SCRATCH/f ] && echo created")
add(F, "echo hello > $SCRATCH/h && cat $SCRATCH/h")
add(F, "echo hello >> $SCRATCH/h2 && echo again >> $SCRATCH/h2 && wc -l < $SCRATCH/h2")
add(F, "mktemp -d >/dev/null && echo ok")
add(F, "chmod 600 $SCRATCH 2>/dev/null; ls -ld $SCRATCH | cut -c1-10")
add(F, "head -3 README.md > $SCRATCH/h && wc -l $SCRATCH/h")

# ---------------- git ----------------
G = "git"
for c in ["git status --short | head", "git status -s | wc -l", "git status --porcelain | cut -c4-", "git status", "git status -sb | head -3",
          "git log --oneline | head -5", "git log --oneline | wc -l", "git log --oneline | tail -3", "git log -3 --format='%h %s'", "git log --format=%s | sort | uniq -c | sort -rn | head -3",
          "git log --format=%an | sort | uniq -c", "git log --oneline --decorate | head -3", "git log --stat -1 | tail -3", "git log -1 --format=%H", "git log -p -1 | head -20",
          "git log --oneline -- src/go | head -3", "git log --oneline -- README.md", "git log --format='%ad' --date=iso | head -2", "git log --since=2023-11-20 --oneline | wc -l",
          "git ls-files | head", "git ls-files | wc -l", "git ls-files '*.go' | head -5", "git ls-files '*.py' | wc -l", "git ls-files src | cut -d/ -f2 | sort | uniq -c",
          "git ls-files | cut -d/ -f1 | sort | uniq -c | sort -rn", "git ls-files | rg '\\.py$' | head -3", "git ls-files | grep -c '\\.ts$'", "git ls-files -m", "git ls-files --others --exclude-standard",
          "git ls-files src/py | xargs wc -l | tail -1", "git ls-files src/go | head -20 | xargs wc -l | tail -1", "wc -l $(git ls-files src/c | head -30) | tail -1", "wc -l $(git ls-files '*.md') | tail -1",
          "git ls-files | xargs grep -l TODO | wc -l", "git ls-files -z src/js | xargs -0 wc -l | tail -1", "git ls-files | head -200 | xargs cat | wc -c",
          "git diff --stat | tail -3", "git diff | head -20", "git diff --name-only", "git diff --numstat", "git diff HEAD~1 --stat | tail -2", "git diff HEAD~3 --name-only | wc -l", "git diff -- README.md",
          "git branch --list", "git branch -a", "git tag", "git tag -l 'v*'", "git rev-parse --short HEAD", "git rev-parse --abbrev-ref HEAD", "git rev-parse --show-toplevel | wc -c",
          "git rev-list --count HEAD", "git rev-list HEAD | head -2", "git show --stat HEAD | head -8", "git show HEAD --name-only --format= | head -3", "git show v0.1.0 --stat | head -4",
          "git cat-file -t HEAD", "git cat-file -p HEAD | head -3", "git blame -L1,5 README.md | cut -c1-8", "git blame -L1,3 src/go/pkg00/f0000.go | wc -l",
          "git grep -n TODO | head", "git grep -c TODO | head -3", "git grep -l FIXME | wc -l", "git grep -n 'func ' -- 'src/go/pkg00' | head -5", "git grep -in handlerequest | head -3",
          "git config --get core.fsmonitor", "git remote -v | wc -l", "git stash list | wc -l", "git describe --tags", "git shortlog -sn HEAD", "git count-objects | wc -l",
          "git ls-tree HEAD | head -5", "git ls-tree -r HEAD --name-only | wc -l", "git ls-tree -r HEAD --name-only | grep -c '\\.go$'", "git merge-base HEAD feature/x | cut -c1-7",
          "git status --short && git log --oneline | head -2", "git rev-parse --is-inside-work-tree && git ls-files | head -2", "git diff --quiet; echo $?", "git diff --cached --quiet && echo clean",
          "git log --oneline | head -3 && git status -s | head -3", "git log --graph --oneline | head -5", "git check-ignore node_modules && echo ignored", "git check-ignore -v logs/app.log | cut -c1-20",
          "git for-each-ref --format='%(refname:short)' | sort", "git name-rev --name-only HEAD", "git log -1 --pretty=%s | tr a-z A-Z", "git log --oneline | cut -d' ' -f2- | sort | uniq -c | sort -rn | head -3"]:
    add(G, c)

# ---------------- control flow ----------------
C = "control-flow"
for d in pick(SMALLDIRS, 6):
    add(C, f"for f in {d}/*; do echo \"$f\"; done | head -{rng.choice(N)}")
    add(C, f"for f in {d}/*; do wc -l \"$f\"; done | tail -{rng.choice([2, 3, 5])}")
    add(C, f"for f in {d}/*; do head -1 \"$f\" | cut -c1-30; done | sort | uniq -c | sort -rn | head -3")
    add(C, f"for f in {d}/*; do grep -c TODO \"$f\"; done | sort | uniq -c")
    add(C, f"for f in {d}/*; do [ -s \"$f\" ] && echo \"$f\"; done | wc -l")
    add(C, f"n=0; for f in {d}/*; do n=$((n+1)); done; echo $n")
    add(C, f"for f in $(ls {d} | head -4); do echo \"== $f\"; head -2 {d}/$f | cut -c1-30; done")
    add(C, f"while read -r l; do echo \"${{l%% *}}\"; done < <(ls -1 {d} | head -5)")
    add(C, f"for f in {d}/*; do echo \"${{f##*/}}\"; done | head -3")
    add(C, f"for f in {d}/*; do b=${{f##*/}}; echo \"${{b%.*}}\"; done | head -3")
for e in pick(EXTS[:6], 4):
    add(C, f"for f in $(git ls-files '*.{e}' | head -20); do wc -l \"$f\"; done | sort -n | tail -2")
    add(C, f"for f in $(find src -name '*.{e}' | sort | head -10); do echo \"$f $(wc -c < \"$f\")\"; done | tail -3")
add(C, "for d in src/*; do echo \"$d $(ls $d | wc -l)\"; done")
add(C, "for d in src/*/; do echo \"${d%/} $(find $d -type f | wc -l)\"; done")
add(C, "for i in 1 2 3 4 5; do echo \"item $i\"; done")
add(C, "for i in $(seq 1 50); do echo $i; done | tail -2")
add(C, "for i in {1..20}; do echo $((i*i)); done | tail -3")
add(C, "for i in a b c; do for j in 1 2; do echo $i$j; done; done")
add(C, "for ((i=0;i<10;i++)); do echo $i; done | tail -2")
add(C, "i=0; while [ $i -lt 100 ]; do i=$((i+1)); done; echo $i")
add(C, "i=0; while [ $i -lt 1000 ]; do i=$((i+1)); done; echo $i")
add(C, "i=0; until [ $i -ge 10 ]; do i=$((i+2)); done; echo $i")
add(C, "i=0; while true; do i=$((i+1)); [ $i -ge 5 ] && break; done; echo $i")
add(C, "for i in 1 2 3 4 5 6; do [ $((i%2)) -eq 0 ] && continue; echo $i; done")
add(C, "while read -r line; do echo \"$line\"; done < data/kv.env | head -5")
add(C, "while read -r line; do echo \"${line%%=*}\"; done < data/kv.env | tail -3")
add(C, "while IFS== read -r k v; do echo \"$v\"; done < data/kv.env | sort -n | tail -2")
add(C, "while IFS=, read -r id name email age cc; do [ \"$age\" -gt 78 ] && echo \"$name\"; done < <(head -500 data/users.csv | tail -n +2) | head -5")
add(C, "c=0; while read -r l; do c=$((c+1)); done < data/words.txt; echo $c")
add(C, "head -2000 data/words.txt | while read -r w; do echo ${#w}; done | sort -n | tail -1")
add(C, "cat data/kv.env | while read -r l; do echo \"$l\"; done | wc -l")
add(C, "if [ -f README.md ]; then head -1 README.md; else echo missing; fi")
add(C, "if [ -d src ] && [ -d docs ]; then echo both; fi")
add(C, "if grep -q TODO README.md; then echo todo; else echo clean; fi")
add(C, "if [ \"$(wc -l < README.md)\" -gt 2 ]; then echo long; else echo short; fi")
add(C, "if ! [ -e nonexistent ]; then echo absent; fi")
add(C, "if [[ -f README.md && -s README.md ]]; then echo ok; fi")
add(C, "if [[ \"abc\" == a* ]]; then echo glob; fi")
add(C, "if [[ \"abc123\" =~ ^[a-z]+([0-9]+)$ ]]; then echo ${BASH_REMATCH[1]}; fi")
add(C, "x=5; if (( x > 3 )); then echo big; fi")
add(C, "x=hello; case $x in h*) echo starts-h;; *) echo other;; esac")
add(C, "for f in README.md Makefile package.json; do case $f in *.md) echo doc;; *.json) echo json;; *) echo other;; esac; done")
add(C, "case \"$(uname -s)\" in Linux) echo linux;; *) echo other;; esac")
add(C, "f() { echo \"arg: $1\"; }; f one; f two")
add(C, "count() { ls \"$1\" | wc -l; }; count src; count docs")
add(C, "add() { echo $(( $1 + $2 )); }; add 2 3")
add(C, "fact() { [ $1 -le 1 ] && echo 1 || echo $(( $1 * $(fact $(( $1 - 1 )) ) )); }; fact 8")
add(C, "fib() { local a=0 b=1 i; for ((i=0;i<$1;i++)); do local t=$((a+b)); a=$b; b=$t; done; echo $a; }; fib 30")
add(C, "x=$(cat data/oneline.txt); echo \"${x^^}\"")
add(C, "x=$(head -1 README.md); echo \"${#x}\"")
add(C, "x=src/go/pkg00/f0000.go; echo ${x##*/} ${x%/*} ${x%.go}")
add(C, "arr=(a b c d); echo ${#arr[@]} ${arr[2]} ${arr[@]:1:2}")
add(C, "declare -A m=([a]=1 [b]=2); for k in a b; do echo $k=${m[$k]}; done")
add(C, "arr=($(ls src)); echo ${#arr[@]}; for x in \"${arr[@]}\"; do echo $x; done")
add(C, "mapfile -t lines < <(head -5 data/words.txt); echo ${#lines[@]}")
add(C, "echo \"count: $(ls | wc -l)\"")
add(C, "echo \"files: $(git ls-files | wc -l) tracked\"")
add(C, "n=$(git ls-files | wc -l); echo $((n / 2))")
add(C, "echo $(echo $(echo nested))")
add(C, "a=1; b=2; echo $((a+b)) $((a*b)) $((b**3)) $((b%2))")
add(C, "export FOO=bar; env | grep '^FOO='")
add(C, "FOO=bar sh -c 'echo $FOO'")
add(C, "(cd src && ls | head -2)")
add(C, "(cd src/go && pwd); pwd")
add(C, "{ echo a; echo b; } | wc -l")
add(C, "true && echo yes")
add(C, "false || echo fallback")
add(C, "false; echo $?")
add(C, "ls nonexistent 2>/dev/null; echo $?")
add(C, "grep -q nomatch README.md || echo none")
add(C, "set -e; false; echo not reached")
add(C, "set -o pipefail; false | true; echo $?")
add(C, "false | true; echo ${PIPESTATUS[0]} ${PIPESTATUS[1]}")
add(C, "trap 'echo bye' EXIT; echo run")
add(C, "set -u; echo ${undefined_var:-default}")
add(C, "echo ${undefined:-d} ${undefined:=e} ${undefined:+f}")
add(C, "command -v git >/dev/null && echo has git")
add(C, "command -v nonexistent_cmd || echo missing")
add(C, "type cd | head -1")
add(C, "type -t ls")
add(C, "cd src && ls | head -3 && cd .. && pwd")
add(C, "cd src/go && ls | head -3 && cd ../py && ls | head -3")
add(C, "cd docs && ls | wc -l && cd .. && ls | wc -l")
add(C, "cd nonexistent 2>&1 | head -1")
add(C, "cd src && cd go && cd pkg00 && ls | head -2")
add(C, "cd data && wc -l *.txt | tail -1 && cd -")
add(C, "mkdir -p $SCRATCH/a/b && echo hi > $SCRATCH/a/b/c && cat $SCRATCH/a/b/c && rm -rf $SCRATCH/a")
add(C, "test -d node_modules && ls node_modules | wc -l")
add(C, "[ -f README.md ] && [ -f Makefile ] && echo both")
add(C, "[ -n \"$HOME\" ] && echo home")
add(C, "[ -z \"$UNSETVAR\" ] && echo empty")
add(C, "[ 3 -lt 5 ] && [ 5 -gt 3 ] && echo ordered")
add(C, "[ \"a\" = \"a\" ] && echo eq")
add(C, "[ \"a\" != \"b\" ] && echo ne")
add(C, "read -r a b <<< 'x y z'; echo \"$a|$b\"")
add(C, "echo 'a b c' | { read -r x y z; echo $z; }")
add(C, "printf '%s-%s\\n' a b")
add(C, "printf '%05d %x %o\\n' 42 255 8")
add(C, "printf '%-5s|%5s|\\n' ab cd")
add(C, "echo -n abc; echo")
add(C, "echo -e 'a\\tb'")
add(C, "echo $#; set -- a b c; echo $# $1 $@")
add(C, "set -- x y z; shift; echo $@")
add(C, "echo \"$@\" \"$*\"")
add(C, "IFS=:; set -- $PATH; echo $# | wc -c")
add(C, "echo ${PWD##*/} | wc -c")
add(C, "echo $RANDOM | wc -c | tr -d ' ' >/dev/null; echo ok")
add(C, "echo ~ | wc -c >/dev/null; echo tilde")
add(C, "eval 'echo evaled'")
add(C, "source /dev/stdin <<< 'echo sourced'")
add(C, "exit 3")
add(C, "echo before; exit 0; echo after")
add(C, "return_test() { return 4; }; return_test; echo $?")
add(C, "local_test() { local x=1; echo $x; }; x=2; local_test; echo $x")
add(C, "getopts_test() { while getopts 'ab:' o; do echo \"opt $o $OPTARG\"; done; }; getopts_test -a -b val")
add(C, "wait; echo waited")
add(C, "sleep 0.01 & wait; echo bg-done")
add(C, "echo hi >&2; echo out")
add(C, "{ echo err >&2; echo out; } 2>&1 | sort")
add(C, "ls nonexistent 2>&1 | head -1")
add(C, "echo a > /dev/null; echo $?")
add(C, "exec 3>&1; echo fd3 >&3")
add(C, "diff -q README.md README.md && echo same")
add(C, "yes | head -n 1000 | wc -l")
add(C, "echo $(( $(date +%Y) > 2000 ))")
add(C, "echo 'unterminated")
add(C, "echo ok; if then fi")
add(C, "nonexistent_command_xyz; echo $?")
add(C, "nonexistent_command_xyz 2>&1 | head -1")
# heredocs
add(C, "cat <<EOF\nhello\nworld\nEOF")
add(C, "cat <<'EOF'\nliteral $HOME `x`\nEOF")
add(C, "cat <<EOF\nhome set: ${HOME:+yes}\nsum: $((1+2))\nEOF")
add(C, "cat <<-EOF\n\tindented\n\tlines\nEOF")
add(C, "cat <<'EOF' | wc -l\na\nb\nc\nEOF")
add(C, "cat <<'EOF' | grep b\na\nb\nc\nEOF")
add(C, "cat <<'EOF' > $SCRATCH/h.txt\nline1\nline2\nEOF\nwc -l $SCRATCH/h.txt")
add(C, "cat > $SCRATCH/s.sh <<'EOF'\necho from script\nEOF\nbash $SCRATCH/s.sh")
add(C, "python3 - <<'EOF'\nprint(sum(i*i for i in range(10)))\nEOF")
add(C, "python3 - <<'EOF'\nimport json\nprint(json.dumps({'a': 1}))\nEOF")
add(C, "bash <<'EOF'\necho nested bash\nEOF")
add(C, "while read -r a b; do echo \"$b $a\"; done <<EOF\n1 x\n2 y\nEOF")
add(C, "sort <<EOF | head -2\nc\nb\na\nEOF")
add(C, "cat <<EOF >> $SCRATCH/app.txt\nappended\nEOF\ncat $SCRATCH/app.txt | wc -l; rm -f $SCRATCH/app.txt")
add(C, "tr a-z A-Z <<< 'here string'")
add(C, "wc -w <<< 'one two three'")
add(C, "cat <<EOF\n$(ls src | head -3)\nEOF")
add(C, "f() { cat <<EOF\nin func $1\nEOF\n}; f arg")
add(C, "cat <<A; cat <<B\nfirst\nA\nsecond\nB")

for d in SMALLDIRS:
    add(C, f"cd {d} && grep -rn 'TODO' . | head -5")
    add(C, f"cd {d} && wc -l * | tail -1")
    add(C, f"cd {d} && head -3 $(ls | head -1)")
    add(C, f"cd {d} && ls && pwd")
    add(C, f"[ -d {d} ] && ls {d} | head -2 && echo ok")
    add(C, f"cd {d} && ls | head -1 | xargs wc -c")
for f in pick(FILES, 10):
    add(C, f"test -f {f} && head -3 {f}")
    add(C, f"[ -f {f} ] && wc -l {f} && echo counted")
    add(C, f"cat {f} | head -2 && echo done")
for i in range(6):
    n = rng.choice([2, 3, 5])
    add(C, f"cat <<'EOF' | head -{n}\n" + "\n".join(f"row {j} {rng.choice(PATS)}" for j in range(6)) + "\nEOF")
    add(C, f"cat > $SCRATCH/n{i}.txt <<'EOF'\nalpha {i}\nbeta\nEOF\ngrep -c a $SCRATCH/n{i}.txt")
    add(C, f"cat <<EOF\nsrc has $(ls src | wc -l) entries ({i})\nEOF")
    add(C, f"python3 - <<'EOF'\nprint({i} * 7)\nEOF")

# ---------------- startup ----------------
ST = "startup"
for c in ["true", "echo hi", "pwd", "echo $((1+2))", "cd src && pwd", "ls | head -1", "[ -d src ] && echo y", "x=5; echo $x", "test -f README.md", "echo a b c | wc -w",
          "printf '%s\\n' hi", "head -1 README.md", "cat data/oneline.txt", "wc -l README.md", "type cd", "command -v ls", "echo \"$(echo nested)\"", "false || echo fallback",
          "export X=1; echo $X", "(echo sub)", ":", "echo", "ls /", "echo $HOME | wc -c", "cd /; pwd", "echo hi | cat", "echo hi | head -1", "uname -s", "id -u | wc -c", "whoami | wc -c"]:
    add(ST, c)

# ---------------- prune against real bash ----------------
def run_bash(cmd):
    env = {"PATH": os.environ["PATH"], "HOME": "/nonexistent", "LC_ALL": "C", "LANG": "C", "TZ": "UTC", "USER": "bench", "LOGNAME": "bench", "TERM": "dumb",
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_OPTIONAL_LOCKS": "0", "SCRATCH": "/tmp/zash-gen-scratch"}
    os.makedirs(env["SCRATCH"], exist_ok=True)
    r = subprocess.run(["bash", "--norc", "--noprofile", "-c", cmd], cwd=fixture, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    return r.stdout, r.stderr, r.returncode

if os.path.isdir(fixture):
    kept = []
    for e in entries:
        if any(not os.path.exists(os.path.join(fixture, r)) for r in e[1]):
            kept.append(e); continue
        a_, b_ = run_bash(e[2]), run_bash(e[2])
        if a_ != b_:
            print("drop nondeterministic:", e[2][:70]); continue
        if e[0] != "startup" and not a_[0] and a_[2] == 0 and not a_[1]:
            continue
        kept.append(e)
    print(f"pruned {len(entries) - len(kept)} of {len(entries)}")
    entries = kept
else:
    print("no fixture, skipping prune", file=sys.stderr)

# ---------------- trim to a runnable size ----------------
CAP = {"search": 110, "text-pipeline": 130, "fs-listing": 110, "git": 70, "control-flow": 190, "startup": 28}
def has_pipe(e): return "|" in e[2].replace("||", "")
trimmed = []
for cat, cap in CAP.items():
    es = [e for e in entries if e[0] == cat]
    keep = {id(e) for e in es if e[1]}
    rest = [e for e in es if not e[1]]
    rng.shuffle(rest)
    simple = [e for e in rest if not has_pipe(e)]
    piped = [e for e in rest if has_pipe(e)]
    room = max(0, cap - len(keep))
    chosen = simple[: room // 2]
    chosen += piped[: room - len(chosen)]
    chosen += simple[room // 2 : room // 2 + room - len(chosen)]
    keep |= {id(e) for e in chosen}
    trimmed += [e for e in es if id(e) in keep]
entries = trimmed

# ---------------- write ----------------
os.makedirs(out, exist_ok=True)
for f in glob.glob(os.path.join(out, "*.sh")): os.remove(f)
catn = {}
for i, (cat, req, cmd) in enumerate(entries):
    catn[cat] = catn.get(cat, 0) + 1
    hdr = f"# cat: {cat}\n" + "".join(f"# requires: {r}\n" for r in req)
    with open(os.path.join(out, f"{i:03d}-{cat}.sh"), "w") as f:
        f.write(hdr + cmd + "\n")
print(len(entries), catn)

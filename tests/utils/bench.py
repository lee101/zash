import os, sys, subprocess, time, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness

BIG = os.environ.get("ZBENCH_FILE", "/tmp/zbench/big100.txt")
FAST = os.path.join(harness.REPO, ".zig-cache", "zutil_fast")


def timeit(argv, exe=None, stdin=False, runs=5):
    best = 1e9
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
    out = open("/tmp/zbench/out.bin", "wb")
    for _ in range(runs):
        sin = open(BIG, "rb") if stdin else None
        t0 = time.perf_counter()
        subprocess.run(argv, executable=exe, stdin=sin, stdout=out, stderr=subprocess.DEVNULL, env=env)
        best = min(best, time.perf_counter() - t0)
        if sin:
            sin.close()
    out.close()
    return best


def stdin_file():
    return open(BIG, "rb")


BENCHES = {
    "head": [["head", "-n", "10", BIG], ["head", "-n", "-5", BIG], ["head", "-c", "1000000", BIG]],
    "tail": [["tail", "-n", "10", BIG], ["tail", "-n", "+99000", BIG], ["tail", "-c", "100000", BIG]],
    "cat": [["cat", BIG], ["cat", "-n", BIG], ["cat", "-s", BIG]],
    "wc": [["wc", "-l", BIG], ["wc", BIG], ["wc", "-w", BIG], ["wc", "-c", BIG], ["wc", "-m", BIG]],
    "cut": [["cut", "-d", " ", "-f2", BIG], ["cut", "-c1-20", BIG], ["cut", "-d:", "-f1", BIG]],
    "tr": [["tr", "a-z", "A-Z"], ["tr", "-d", "\\n"], ["tr", "-cs", "a-z", "\\n"]],
    "grep": [["grep", "NEEDLE_RARE", BIG], ["grep", "-c", "error", BIG], ["grep", "-c", "-E", "error|warning", BIG], ["grep", "-c", "-i", "ERROR", BIG], ["grep", "-c", "-E", "^[0-9]+: alpha .*(foo|bar)$", BIG], ["grep", "-n", "NEEDLE_RARE", BIG], ["grep", "-c", "-v", "e", BIG], ["grep", "-c", "-w", "foo", BIG], ["grep", "-o", "-E", "NEEDLE_RARE_[0-9]+", BIG], ["grep", "-c", "-F", "-e", "alpha beta", "-e", "gamma delta", BIG]],
}


def main():
    utils = sys.argv[1:] or list(BENCHES)
    harness.build("ReleaseFast", FAST)
    print("%-6s %-60s %9s %9s %6s" % ("util", "args", "gnu(ms)", "zash(ms)", "ratio"))
    for u in utils:
        for args in BENCHES[u]:
            needs_stdin = u == "tr"
            g = timeit(args, harness.gnu_path(u), needs_stdin)
            z = timeit([FAST] + args, None, needs_stdin)
            short = " ".join(a.replace(BIG, "BIG") for a in args[1:])
            print("%-6s %-60s %9.1f %9.1f %6.2f" % (u, short[:60], g * 1000, z * 1000, g / z))


if __name__ == "__main__":
    main()

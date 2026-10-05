from harness import Case
import lsfix

OPTS = [[], ["-1"], ["-a"], ["-A"], ["-l"], ["-la"], ["-lA"], ["-lh"], ["-lah"], ["-F"], ["-p"], ["-t"], ["-S"], ["-r"], ["-tr"], ["-Sr"], ["-lt"], ["-ltr"], ["-lS"], ["-lSh"],
        ["-R"], ["-lR"], ["-aR"], ["-d"], ["-ld"], ["-n"], ["-ln"], ["-U"], ["-lF"], ["-F", "-l"], ["-l", "-1"], ["-1", "-l"], ["--color=never"], ["--sort=size"], ["--sort=time", "-l"],
        ["--all", "--human-readable", "-l"], ["-FR"], ["-lFR"], ["-pR"], ["-aF"], ["-ltaF"], ["-A", "-a"], ["-a", "-A"], ["-lU"], ["--almost-all", "-F"], ["--recursive", "--reverse"]]

TARGETS = [[], ["lsx"], ["lsx/"], ["lsx/sub"], ["nofile"], ["lsx/a.txt"], ["lsx/link_dir"], ["lsx/link_dir/"], ["lsx/link_file"], ["lsx/dangling"], ["lsx/sub", "lsx/empty"],
           ["lsx/a.txt", "lsx/sub"], ["lsx/a.txt", "lsx/B.txt", "lsx/zeta"], ["nofile", "lsx/sub"], ["lsx/empty"], ["lsx/many"], ["lsx/sticky", "lsx/sgdir"], ["lsx/fifo", "lsx/sock", "lsx/exec.sh"],
           ["lsx/link_exec", "lsx/link_fifo", "lsx/link_rel"], ["lsx/sub", "lsx/sub"], ["lsx/sub/", "lsx/a.txt", "lsx/link_dir"], ["emptydir"], ["dir"], ["rtree"], ["/dev/null", "lsx/a.txt"], ["/dev/null"], ["/dev/null", "/dev/zero", "lsx/s1024"],
           ["lsx/suid", "lsx/suid0", "lsx/sgid", "lsx/ro"], ["lsx/s1023", "lsx/s1024", "lsx/s1025", "lsx/s10239", "lsx/s10240", "lsx/s10241", "lsx/s1048575", "lsx/s1048576", "lsx/s5m1", "lsx/s999", "lsx/s100k", "lsx/s2g"], [".."], ["./lsx/../lsx/sub"], ["-"]]


def cases(fx):
    lsfix.build(fx)
    for o in OPTS:
        for t in TARGETS:
            yield Case(["ls"] + o + t)
    yield Case(["ls", "-l", "--", "lsx/a.txt"])
    yield Case(["ls", "--", "-"])
    yield Case(["ls", "-lh", "lsx"])
    yield Case(["ls", "-la", "lsx", "lsx/sub", "nofile", "lsx/a.txt"])
    yield Case(["ls", "-C"], unsupported=True)
    yield Case(["ls", "-x"], unsupported=True)
    yield Case(["ls", "-m"], unsupported=True)
    yield Case(["ls", "--color"], unsupported=True)
    yield Case(["ls", "--color=always"], unsupported=True)
    yield Case(["ls", "--color=auto"], unsupported=True)
    yield Case(["ls", "-i"], unsupported=True)
    yield Case(["ls", "-s"], unsupported=True)
    yield Case(["ls", "-L"], unsupported=True)
    yield Case(["ls", "--time-style=iso", "-l"], unsupported=True)
    yield Case(["ls", "--sort=version"], unsupported=True)
    yield Case(["ls", "-l"], env={"TZ": "Asia/Tokyo"}, unsupported=True)
    yield Case(["ls", "-l", "lsx"], env={"TZ": "UTC"})
    yield Case(["ls"], env={"LC_ALL": "en_US.UTF-8"}, unsupported=True)
    yield Case(["ls", "lsx"], env={"LC_ALL": "C.UTF-8"})
    yield Case(["ls"], env={"LC_ALL": "", "LANG": "en_GB.UTF-8"}, unsupported=True)
    yield Case(["ls"], env={"QUOTING_STYLE": "shell"}, unsupported=True)
    yield Case(["ls", "-l"], env={"TIME_STYLE": "long-iso"}, unsupported=True)
    yield Case(["ls", "-l"], env={"BLOCK_SIZE": "1M"}, unsupported=True)
    yield Case(["ls", "-l", "lsx"], env={"LC_ALL": "C.UTF-8"})

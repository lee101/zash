import os, socket, time


def build(fx):
    root = os.path.join(fx, "lsx")
    if os.path.exists(root):
        return
    os.makedirs(root)

    def w(name, data=b"x", mode=None):
        p = os.path.join(root, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        if mode is not None:
            os.chmod(p, mode)

    for n, sz in [("a.txt", 10), ("B.txt", 20), (".hidden", 5), ("zeta", 0), ("sp ace", 7), ("1.txt", 1), ("10.txt", 2), ("2.txt", 3),
                  ("s1023", 1023), ("s1024", 1024), ("s1025", 1025), ("s10239", 10239), ("s10240", 10240), ("s10241", 10241),
                  ("s1048575", 1048575), ("s1048576", 1048576), ("s5m1", 5 * 1048576 + 1), ("s999", 999), ("s100k", 102400), ("s2g", 2 * 1073741824)]:
        w(n, b"")
        os.truncate(os.path.join(root, n), sz)
    w("exec.sh", b"#!/bin/sh\n", 0o755)
    w("suid", b"x", 0o4755)
    w("suid0", b"x", 0o4644)
    w("sgid", b"x", 0o2755)
    w("ro", b"x", 0o444)
    w("sub/f1", b"abc")
    w("sub/f2", b"abcdef")
    w("sub/deep/x", b"1")
    w("sub/deep/deeper/y", b"1")
    w("sub/.dot", b"1")
    os.makedirs(os.path.join(root, "empty"))
    os.makedirs(os.path.join(root, "sticky"), exist_ok=True)
    os.chmod(os.path.join(root, "sticky"), 0o1777)
    os.makedirs(os.path.join(root, "sgdir"), exist_ok=True)
    os.chmod(os.path.join(root, "sgdir"), 0o2755)
    for i in range(12):
        os.makedirs(os.path.join(root, "many", "d%d" % i))
    os.mkfifo(os.path.join(root, "fifo"))
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(root, "sock"))
    s.close()
    os.symlink("a.txt", os.path.join(root, "link_file"))
    os.symlink("sub", os.path.join(root, "link_dir"))
    os.symlink("nonexistent", os.path.join(root, "dangling"))
    os.symlink("exec.sh", os.path.join(root, "link_exec"))
    os.symlink("../lsx/sub/f1", os.path.join(root, "link_rel"))
    os.symlink("fifo", os.path.join(root, "link_fifo"))
    names = []
    for dp, dn, fn in os.walk(root, topdown=False):
        for n in fn + dn:
            names.append(os.path.join(dp, n))
        names.append(dp)
    now = time.time_ns()
    old = int(time.mktime((2020, 6, 15, 12, 34, 56, 0, 0, 0)) - time.timezone) * 10**9
    cands = [
        old,
        old + 86400 * 400 * 10**9,
        now - 3 * 86400 * 10**9 - 123456789,
        now - 100 * 86400 * 10**9,
        now + 5 * 86400 * 10**9,
        now - 400 * 86400 * 10**9,
        old,
        old + 1,
        old + 2,
    ]
    names.sort()
    for i, p in enumerate(names):
        t = cands[(i * 7 + len(os.path.basename(p))) % len(cands)]
        os.utime(p, ns=(t, t), follow_symlinks=False)

    def setm(rel, ns):
        os.utime(os.path.join(root, rel), ns=(ns, ns), follow_symlinks=False)

    setm("a.txt", old + 5 * 10**9 + 100)
    setm("B.txt", old + 5 * 10**9 + 200)
    setm("zeta", old + 5 * 10**9 + 200)
    setm("1.txt", old)
    setm("2.txt", old)
    setm("10.txt", old)
    t2 = old + 12345 * 10**9
    for dp, dn, fn in os.walk(fx):
        if dp.startswith(root):
            continue
        for n in fn + dn:
            os.utime(os.path.join(dp, n), ns=(t2, t2), follow_symlinks=False)
    os.utime(fx, ns=(t2, t2))

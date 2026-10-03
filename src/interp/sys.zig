const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const O = struct {
    pub const RDONLY: c_int = 0;
    pub const WRONLY: c_int = 1;
    pub const RDWR: c_int = 2;
    pub const CREAT: c_int = 0o100;
    pub const EXCL: c_int = 0o200;
    pub const NOCTTY: c_int = 0o400;
    pub const TRUNC: c_int = 0o1000;
    pub const APPEND: c_int = 0o2000;
    pub const NONBLOCK: c_int = 0o4000;
    pub const CLOEXEC: c_int = 0o2000000;
    pub const DIRECTORY: c_int = if (builtin.cpu.arch == .aarch64) 0o40000 else 0o200000;
};

pub const F_DUPFD: c_int = 0;
pub const F_GETFD: c_int = 1;
pub const F_SETFD: c_int = 2;
pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const F_DUPFD_CLOEXEC: c_int = 1030;
pub const FD_CLOEXEC: c_int = 1;

pub const WNOHANG: c_int = 1;
pub const SIGINT = 2;
pub const SIGPIPE = 13;
pub const SIGCHLD = 17;

pub const EPERM = 1;
pub const ENOENT = 2;
pub const EINTR = 4;
pub const EBADF = 9;
pub const ECHILD = 10;
pub const EAGAIN = 11;
pub const EACCES = 13;
pub const EEXIST = 17;
pub const ENOTDIR = 20;
pub const EISDIR = 21;
pub const EINVAL = 22;
pub const EPIPE = 32;
pub const ENOEXEC = 8;
pub const ELOOP = 40;
pub const ENAMETOOLONG = 36;
pub const E2BIG = 7;

pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
pub extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
pub extern "c" fn dup(fd: c_int) c_int;
pub extern "c" fn dup2(a: c_int, b: c_int) c_int;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
pub extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
pub extern "c" fn fork() c_int;
pub extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
pub extern "c" fn _exit(code: c_int) noreturn;
pub extern "c" fn kill(pid: c_int, sig: c_int) c_int;
pub extern "c" fn getpid() c_int;
pub extern "c" fn getppid() c_int;
pub extern "c" fn chdir(path: [*:0]const u8) c_int;
pub extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*]u8;
pub extern "c" fn umask(mode: c_uint) c_uint;
pub extern "c" fn isatty(fd: c_int) c_int;
pub extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern "c" fn strerror(e: c_int) [*:0]const u8;
pub extern "c" fn strsignal(sig: c_int) [*:0]const u8;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn getuid() c_uint;
pub extern "c" fn geteuid() c_uint;
pub extern "c" fn getgid() c_uint;
pub extern "c" fn getegid() c_uint;
pub extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
pub extern "c" fn alarm(secs: c_uint) c_uint;
pub extern "c" fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;
pub extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
pub extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, n: usize) isize;
pub extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
pub extern "c" fn getrlimit(res: c_int, lim: *RLimit) c_int;
pub extern "c" fn setrlimit(res: c_int, lim: *const RLimit) c_int;
pub extern "c" fn times(buf: *Tms) c_long;
pub extern "c" fn sysconf(name: c_int) c_long;
pub extern "c" fn gethostname(buf: [*]u8, len: usize) c_int;
pub extern "c" fn getpwnam(name: [*:0]const u8) ?*Passwd;
pub extern "c" fn getpwuid(uid: c_uint) ?*Passwd;
pub extern "c" fn regcomp(preg: *Regex, pattern: [*:0]const u8, cflags: c_int) c_int;
pub extern "c" fn regexec(preg: *const Regex, s: [*:0]const u8, nmatch: usize, pmatch: [*]RegMatch, eflags: c_int) c_int;
pub extern "c" fn regfree(preg: *Regex) void;
pub extern "c" fn tcgetpgrp(fd: c_int) c_int;
pub extern "c" fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int;
pub extern "c" fn getpgrp() c_int;
pub extern "c" fn sigprocmask(how: c_int, set: ?*const SigSet, old: ?*SigSet) c_int;
pub extern "c" fn sigemptyset(set: *SigSet) c_int;
pub extern "c" fn sigaddset(set: *SigSet, sig: c_int) c_int;
pub extern "c" fn sigaction(sig: c_int, act: ?*const SigAction, old: ?*SigAction) c_int;
pub extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
pub extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
pub extern "c" fn getrusage(who: c_int, ru: *RUsage) c_int;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
pub extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
pub extern "c" fn uname(buf: *[390]u8) c_int;

pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
pub const POLLIN: c_short = 1;
pub const POLLOUT: c_short = 4;
pub const RLimit = extern struct { cur: u64, max: u64 };
pub const Tms = extern struct { utime: c_long, stime: c_long, cutime: c_long, cstime: c_long };
pub const Timespec = extern struct { sec: i64, nsec: i64 };
pub const Passwd = extern struct { name: [*:0]const u8, passwd: [*:0]const u8, uid: c_uint, gid: c_uint, gecos: [*:0]const u8, dir: [*:0]const u8, shell: [*:0]const u8 };
pub const RUsage = extern struct { utime: [2]i64, stime: [2]i64, rest: [14]c_long };
pub const Regex = extern struct { buf: [64]u8 align(8) = undefined };
pub const RegMatch = extern struct { so: c_int, eo: c_int };
pub const SigSet = extern struct { bits: [16]u64 = .{0} ** 16 };
pub const SigAction = extern struct {
    handler: usize,
    mask: SigSet = .{},
    flags: c_int = 0,
    restorer: usize = 0,
};

pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;

pub fn errno() c_int {
    return __errno_location().*;
}

pub fn set_signal(sig: c_int, handler: usize) void {
    var act: SigAction = .{ .handler = handler };
    _ = sigemptyset(&act.mask);
    _ = sigaction(sig, &act, null);
}

pub fn get_signal(sig: c_int) usize {
    var old: SigAction = .{ .handler = 0 };
    _ = sigaction(sig, null, &old);
    return old.handler;
}

pub fn msg_for(e: c_int) []const u8 {
    return std.mem.span(strerror(e));
}

pub fn write_all(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return false;
        }
        off += @intCast(n);
    }
    return true;
}

pub fn read_some(fd: c_int, buf: []u8) isize {
    while (true) {
        const n = read(fd, buf.ptr, buf.len);
        if (n < 0 and errno() == EINTR) continue;
        return n;
    }
}

pub fn close_quiet(fd: c_int) void {
    _ = close(fd);
}

pub fn cstr(buf: []u8, s: []const u8) ?[:0]u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub const Stat = struct {
    mode: u32,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: u32,
    atime_sec: i64,
    ino: u64,
    dev: u64,
    uid: u32,
    gid: u32,
    nlink: u32,
    rdev: u64 = 0,

    pub fn is_dev_null(self: Stat) bool {
        return self.is_chr() and self.rdev == ((@as(u64, 1) << 32) | 3);
    }

    pub fn kind(self: Stat) u32 {
        return self.mode & 0o170000;
    }
    pub fn is_dir(self: Stat) bool {
        return self.kind() == 0o040000;
    }
    pub fn is_reg(self: Stat) bool {
        return self.kind() == 0o100000;
    }
    pub fn is_link(self: Stat) bool {
        return self.kind() == 0o120000;
    }
    pub fn is_fifo(self: Stat) bool {
        return self.kind() == 0o010000;
    }
    pub fn is_chr(self: Stat) bool {
        return self.kind() == 0o020000;
    }
    pub fn is_blk(self: Stat) bool {
        return self.kind() == 0o060000;
    }
    pub fn is_sock(self: Stat) bool {
        return self.kind() == 0o140000;
    }
};

fn statx_to(sx: *const linux.Statx) Stat {
    return .{
        .mode = sx.mode,
        .size = sx.size,
        .mtime_sec = sx.mtime.sec,
        .mtime_nsec = sx.mtime.nsec,
        .atime_sec = sx.atime.sec,
        .ino = sx.ino,
        .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor,
        .uid = sx.uid,
        .gid = sx.gid,
        .nlink = sx.nlink,
        .rdev = (@as(u64, sx.rdev_major) << 32) | sx.rdev_minor,
    };
}

pub fn stat_path(path: []const u8, follow: bool) ?Stat {
    var buf: [4096]u8 = undefined;
    const z = cstr(&buf, path) orelse return null;
    var sx: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(linux.AT.FDCWD, z, flags, .{ .MODE = true, .SIZE = true, .MTIME = true, .ATIME = true, .INO = true, .UID = true, .GID = true, .NLINK = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return statx_to(&sx);
}

pub fn stat_fd(fd: c_int) ?Stat {
    var sx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .SIZE = true, .MTIME = true, .ATIME = true, .INO = true, .UID = true, .GID = true, .NLINK = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return statx_to(&sx);
}

pub fn path_exec_ok(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = cstr(&buf, path) orelse return false;
    return access(z, 1) == 0;
}

pub fn path_access(path: []const u8, mode: c_int) bool {
    var buf: [4096]u8 = undefined;
    const z = cstr(&buf, path) orelse return false;
    return access(z, mode) == 0;
}

pub fn now_ns() i128 {
    var ts: Timespec = undefined;
    _ = clock_gettime(0, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn mono_ns() i128 {
    var ts: Timespec = undefined;
    _ = clock_gettime(1, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn sleep_ns(ns: u64) void {
    const ts: Timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = nanosleep(&ts, null);
}

pub fn wifexited(st: c_int) bool {
    return (st & 0x7f) == 0;
}
pub fn wexitstatus(st: c_int) u8 {
    return @intCast((st >> 8) & 0xff);
}
pub fn wifsignaled(st: c_int) bool {
    return ((st & 0x7f) + 1) >> 1 > 0 and (st & 0x7f) != 0x7f and (st & 0x7f) != 0;
}
pub fn wtermsig(st: c_int) u8 {
    return @intCast(st & 0x7f);
}
pub fn status_code(st: c_int) u8 {
    if (wifexited(st)) return wexitstatus(st);
    return @intCast(128 + wtermsig(st));
}

pub fn getcwd_alloc(alloc: std.mem.Allocator) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const p = getcwd(&buf, buf.len) orelse return null;
    const s = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(p)), 0);
    return alloc.dupe(u8, s) catch null;
}

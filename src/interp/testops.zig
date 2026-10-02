const std = @import("std");
const sys = @import("sys.zig");

pub fn file_unary(op: u8, path: []const u8) bool {
    switch (op) {
        'e', 'a' => return sys.stat_path(path, true) != null,
        'f' => return if (sys.stat_path(path, true)) |s| s.is_reg() else false,
        'd' => return if (sys.stat_path(path, true)) |s| s.is_dir() else false,
        'h', 'L' => return if (sys.stat_path(path, false)) |s| s.is_link() else false,
        'b' => return if (sys.stat_path(path, true)) |s| s.is_blk() else false,
        'c' => return if (sys.stat_path(path, true)) |s| s.is_chr() else false,
        'p' => return if (sys.stat_path(path, true)) |s| s.is_fifo() else false,
        'S' => return if (sys.stat_path(path, true)) |s| s.is_sock() else false,
        's' => return if (sys.stat_path(path, true)) |s| s.size > 0 else false,
        'g' => return if (sys.stat_path(path, true)) |s| s.mode & 0o2000 != 0 else false,
        'u' => return if (sys.stat_path(path, true)) |s| s.mode & 0o4000 != 0 else false,
        'k' => return if (sys.stat_path(path, true)) |s| s.mode & 0o1000 != 0 else false,
        'r' => return sys.path_access(path, 4),
        'w' => return sys.path_access(path, 2),
        'x' => return sys.path_access(path, 1),
        'O' => return if (sys.stat_path(path, true)) |s| s.uid == sys.geteuid() else false,
        'G' => return if (sys.stat_path(path, true)) |s| s.gid == sys.getegid() else false,
        'N' => return if (sys.stat_path(path, true)) |s| s.mtime_sec > s.atime_sec else false,
        't' => {
            const fd = std.fmt.parseInt(c_int, path, 10) catch return false;
            return sys.isatty(fd) == 1;
        },
        else => return false,
    }
}

pub fn newer(a: []const u8, b: []const u8) bool {
    const sa = sys.stat_path(a, true);
    const sb = sys.stat_path(b, true);
    if (sa == null) return false;
    if (sb == null) return true;
    if (sa.?.mtime_sec != sb.?.mtime_sec) return sa.?.mtime_sec > sb.?.mtime_sec;
    return sa.?.mtime_nsec > sb.?.mtime_nsec;
}

pub fn older(a: []const u8, b: []const u8) bool {
    const sa = sys.stat_path(a, true);
    const sb = sys.stat_path(b, true);
    if (sb == null) return false;
    if (sa == null) return true;
    if (sa.?.mtime_sec != sb.?.mtime_sec) return sa.?.mtime_sec < sb.?.mtime_sec;
    return sa.?.mtime_nsec < sb.?.mtime_nsec;
}

pub fn same_file(a: []const u8, b: []const u8) bool {
    const sa = sys.stat_path(a, true) orelse return false;
    const sb = sys.stat_path(b, true) orelse return false;
    return sa.ino == sb.ino and sa.dev == sb.dev;
}

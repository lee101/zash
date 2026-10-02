const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const unparse = @import("unparse.zig");
const Shell = shell.Shell;
const Err = shell.Err;

const Saved = struct { fd: c_int, saved: c_int };

pub const Scope = struct {
    list: std.ArrayList(Saved) = .empty,

    pub fn restore(self: *Scope, sh: *Shell) void {
        var i = self.list.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.list.items[i];
            if (s.saved >= 0) {
                _ = sys.dup2(s.saved, s.fd);
                _ = sys.close(s.saved);
            } else _ = sys.close(s.fd);
        }
        self.list.deinit(sh.gpa);
        self.list = .empty;
    }

    fn save(self: *Scope, sh: *Shell, fd: c_int) Err!void {
        for (self.list.items) |s| if (s.fd == fd) return;
        const saved = sys.fcntl(fd, sys.F_DUPFD_CLOEXEC, @as(c_int, 10));
        try self.list.append(sh.gpa, .{ .fd = fd, .saved = if (saved < 0) -1 else saved });
    }
};

fn fail_open(sh: *Shell, target: []const u8) bool {
    sh.msg("{s}: {s}", .{ target, sys.msg_for(sys.errno()) });
    sh.status = 1;
    return false;
}

fn set_fd(sh: *Shell, scope: ?*Scope, src: c_int, dst: c_int) Err!void {
    if (scope) |s| try s.save(sh, dst);
    if (src == dst) {
        const fl = sys.fcntl(dst, sys.F_GETFD);
        if (fl >= 0) _ = sys.fcntl(dst, sys.F_SETFD, fl & ~sys.FD_CLOEXEC);
        return;
    }
    _ = sys.dup2(src, dst);
    _ = sys.close(src);
}

fn make_heredoc_fd(sh: *Shell, text: []const u8) c_int {
    _ = sh;
    if (text.len <= 60000) {
        var fds: [2]c_int = undefined;
        if (sys.pipe(&fds) != 0) return -1;
        _ = sys.write_all(fds[1], text);
        _ = sys.close(fds[1]);
        return fds[0];
    }
    const fd = sys.memfd_create("zash-heredoc", 0);
    if (fd < 0) return -1;
    _ = sys.write_all(fd, text);
    _ = sys.lseek(fd, 0, 0);
    return fd;
}

fn parse_fd_num(s: []const u8) ?c_int {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(c_int, s, 10) catch null;
}

pub fn apply(sh: *Shell, redirs: []const ast.Redirect, scope: ?*Scope) Err!bool {
    for (redirs) |r| {
        if (!try apply_one(sh, r, scope)) return false;
    }
    return true;
}

fn target_fd(sh: *Shell, r: ast.Redirect, default: c_int) Err!?c_int {
    switch (r.fd) {
        .none => return default,
        .num => |n| return @intCast(n),
        .named => |name| {
            _ = name;
            _ = sh;
            return null;
        },
    }
}

fn single_target(sh: *Shell, r: ast.Redirect) Err!?[]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    try expand.word_fields(sh, r.target, &fields);
    if (fields.items.len != 1) {
        const src = try unparse.word_source(sh, r.target);
        sh.msg("{s}: ambiguous redirect", .{src});
        sh.status = 1;
        return null;
    }
    return fields.items[0];
}

fn apply_one(sh: *Shell, r: ast.Redirect, scope: ?*Scope) Err!bool {
    const named = r.fd == .named;
    const default: c_int = switch (r.op) {
        .in, .here_str, .heredoc, .heredoc_strip, .dup_in, .read_write => 0,
        else => 1,
    };
    const fd_opt = try target_fd(sh, r, default);
    switch (r.op) {
        .in, .out, .append, .clobber, .read_write, .out_err, .append_err => {
            const path = (try single_target(sh, r)) orelse return false;
            var buf: [4096]u8 = undefined;
            const z = sys.cstr(&buf, path) orelse {
                sh.msg("{s}: File name too long", .{path});
                sh.status = 1;
                return false;
            };
            var flags: c_int = switch (r.op) {
                .in => sys.O.RDONLY,
                .read_write => sys.O.RDWR | sys.O.CREAT,
                .append, .append_err => sys.O.WRONLY | sys.O.CREAT | sys.O.APPEND,
                else => sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC,
            };
            if (r.op == .out and sh.opt(.noclobber)) {
                if (sys.stat_path(path, true)) |st| {
                    if (st.is_reg()) {
                        sh.msg("{s}: cannot overwrite existing file", .{path});
                        sh.status = 1;
                        return false;
                    }
                    flags = sys.O.WRONLY;
                } else flags = sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL;
            }
            const fd = sys.open(z, flags | sys.O.CLOEXEC, @as(c_uint, 0o666));
            if (fd < 0) return fail_open(sh, path);
            if (named) return bind_named(sh, r, fd);
            if (r.op == .out_err or r.op == .append_err) {
                if (scope) |s| {
                    try s.save(sh, 1);
                    try s.save(sh, 2);
                }
                _ = sys.dup2(fd, 1);
                _ = sys.dup2(fd, 2);
                _ = sys.close(fd);
                return true;
            }
            try set_fd(sh, scope, fd, fd_opt.?);
            return true;
        },
        .dup_in, .dup_out => {
            const word = try expand.word_string(sh, r.target);
            if (std.mem.eql(u8, word, "-")) {
                if (named) {
                    const v = sh.get_scalar(r.fd.named) orelse return true;
                    const n = parse_fd_num(v) orelse return true;
                    _ = sys.close(n);
                    return true;
                }
                if (scope) |s| try s.save(sh, fd_opt.?);
                _ = sys.close(fd_opt.?);
                return true;
            }
            var move = false;
            var w = word;
            if (w.len > 1 and w[w.len - 1] == '-') {
                if (parse_fd_num(w[0 .. w.len - 1]) != null) {
                    move = true;
                    w = w[0 .. w.len - 1];
                }
            }
            const src = parse_fd_num(w) orelse {
                if (r.op == .dup_out and !named and r.fd == .none) {
                    var buf: [4096]u8 = undefined;
                    const z = sys.cstr(&buf, word) orelse return false;
                    const fd = sys.open(z, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC | sys.O.CLOEXEC, @as(c_uint, 0o666));
                    if (fd < 0) return fail_open(sh, word);
                    if (scope) |s| {
                        try s.save(sh, 1);
                        try s.save(sh, 2);
                    }
                    _ = sys.dup2(fd, 1);
                    _ = sys.dup2(fd, 2);
                    _ = sys.close(fd);
                    return true;
                }
                const src = try expand_source(sh, r.target);
                sh.msg("{s}: ambiguous redirect", .{src});
                sh.status = 1;
                return false;
            };
            if (sys.fcntl(src, sys.F_GETFD) < 0) {
                sh.msg("{d}: Bad file descriptor", .{src});
                sh.status = 1;
                return false;
            }
            if (named) {
                const nfd = sys.fcntl(src, sys.F_DUPFD, @as(c_int, 10));
                if (nfd < 0) return fail_open(sh, w);
                const txt = try sh.tmp_fmt("{d}", .{nfd});
                try assign_named(sh, r.fd.named, txt);
                return true;
            }
            const dst = fd_opt.?;
            if (scope) |s| try s.save(sh, dst);
            if (src != dst) {
                _ = sys.dup2(src, dst);
            } else {
                const fl = sys.fcntl(dst, sys.F_GETFD);
                if (fl >= 0) _ = sys.fcntl(dst, sys.F_SETFD, fl & ~sys.FD_CLOEXEC);
            }
            if (move and src != dst) _ = sys.close(src);
            return true;
        },
        .here_str => {
            const w = try expand.word_string(sh, r.target);
            const text = try std.mem.concat(sh.sa, u8, &.{ w, "\n" });
            const fd = make_heredoc_fd(sh, text);
            if (fd < 0) return fail_open(sh, "here-document");
            if (named) return bind_named(sh, r, fd);
            try set_fd(sh, scope, fd, fd_opt.?);
            return true;
        },
        .heredoc, .heredoc_strip => {
            const h = r.heredoc orelse return true;
            const text = try expand.heredoc_string(sh, h.body);
            const fd = make_heredoc_fd(sh, text);
            if (fd < 0) return fail_open(sh, "here-document");
            if (named) return bind_named(sh, r, fd);
            try set_fd(sh, scope, fd, fd_opt.?);
            return true;
        },
    }
}

fn expand_source(sh: *Shell, w: ast.Word) Err![]const u8 {
    return unparse.word_source(sh, w);
}

fn assign_named(sh: *Shell, name: []const u8, txt: []const u8) Err!void {
    try sh.assign_scalar(name, txt, false);
}

fn bind_named(sh: *Shell, r: ast.Redirect, fd: c_int) Err!bool {
    const nfd = sys.fcntl(fd, sys.F_DUPFD, @as(c_int, 10));
    _ = sys.close(fd);
    if (nfd < 0) return fail_open(sh, r.fd.named);
    const txt = try sh.tmp_fmt("{d}", .{nfd});
    try assign_named(sh, r.fd.named, txt);
    return true;
}

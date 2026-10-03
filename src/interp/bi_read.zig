const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const vars_mod = @import("vars.zig");
const strutil = @import("strutil.zig");
const Shell = shell.Shell;
const Err = shell.Err;

const ByteSrc = struct {
    fd: c_int,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    seekable: bool,
    deadline_ns: ?i128 = null,
    timed_out: bool = false,

    fn init(fd: c_int) ByteSrc {
        return .{ .fd = fd, .seekable = sys.lseek(fd, 0, 1) >= 0 };
    }

    fn wait_ready(self: *ByteSrc) bool {
        const dl = self.deadline_ns orelse return true;
        while (true) {
            const now = sys.mono_ns();
            var ms: i128 = @divTrunc(dl - now, 1_000_000);
            if (ms < 0) ms = 0;
            var pfd = [_]sys.PollFd{.{ .fd = self.fd, .events = sys.POLLIN, .revents = 0 }};
            const r = sys.poll(&pfd, 1, @intCast(@min(ms, 1 << 30)));
            if (r < 0 and sys.errno() == sys.EINTR) continue;
            if (r == 0) {
                self.timed_out = true;
                return false;
            }
            return true;
        }
    }

    fn next(self: *ByteSrc) ?u8 {
        if (self.pos < self.len) {
            const b = self.buf[self.pos];
            self.pos += 1;
            return b;
        }
        if (!self.wait_ready()) return null;
        const want: usize = if (self.seekable) self.buf.len else 1;
        const n = sys.read_some(self.fd, self.buf[0..want]);
        if (n <= 0) return null;
        self.len = @intCast(n);
        self.pos = 1;
        return self.buf[0];
    }

    fn finish(self: *ByteSrc) void {
        if (self.seekable and self.pos < self.len) {
            _ = sys.lseek(self.fd, -@as(i64, @intCast(self.len - self.pos)), 1);
        }
        self.len = 0;
        self.pos = 0;
    }
};

pub fn read_line_fd(sh: *Shell, fd: c_int, line: *std.ArrayList(u8), delim: u8) bool {
    var src = ByteSrc.init(fd);
    defer src.finish();
    while (src.next()) |b| {
        if (b == delim) return true;
        line.append(sh.sa, b) catch return false;
    }
    return false;
}

fn invalid_ident(sh: *Shell, name: []const u8, bname: []const u8) u8 {
    sh.bmsg(bname, "`{s}': not a valid identifier", .{name});
    return 1;
}

fn is_ifs_char(ifs: []const u8, c: u8) bool {
    return std.mem.findScalar(u8, ifs, c) != null;
}

fn is_ifs_ws(ifs: []const u8, c: u8) bool {
    return (c == ' ' or c == '\t' or c == '\n') and is_ifs_char(ifs, c);
}

const Rec = struct {
    text: []u8,
    esc: []bool,
};

fn split_fields(sh: *Shell, rec: Rec, ifs: []const u8, nvars: usize, all: bool, out: *std.ArrayList([]const u8)) Err!void {
    const a = sh.sa;
    const t = rec.text;
    const e = rec.esc;
    var pos: usize = 0;
    while (pos < t.len and !e[pos] and is_ifs_ws(ifs, t[pos])) pos += 1;
    var k: usize = 0;
    while (true) {
        if (pos >= t.len) break;
        const is_last = !all and k + 1 == nvars;
        var fe = pos;
        while (fe < t.len and (e[fe] or !is_ifs_char(ifs, t[fe]))) fe += 1;
        if (is_last) {
            var end = t.len;
            if (fe < t.len and !is_ifs_ws(ifs, t[fe])) {
                var q = fe + 1;
                while (q < t.len and !e[q] and is_ifs_ws(ifs, t[q])) q += 1;
                if (q == t.len) end = fe;
            }
            while (end > pos and !e[end - 1] and is_ifs_ws(ifs, t[end - 1])) end -= 1;
            try out.append(a, t[pos..end]);
            break;
        }
        try out.append(a, t[pos..fe]);
        k += 1;
        if (fe >= t.len) break;
        var q = fe;
        while (q < t.len and !e[q] and is_ifs_ws(ifs, t[q])) q += 1;
        if (q < t.len and !e[q] and is_ifs_char(ifs, t[q]) and !is_ifs_ws(ifs, t[q])) {
            q += 1;
            while (q < t.len and !e[q] and is_ifs_ws(ifs, t[q])) q += 1;
        }
        pos = q;
    }
}

fn unesc(a: std.mem.Allocator, t: []const u8, e: []const bool, strip: bool) Err![]const u8 {
    _ = e;
    _ = strip;
    return a.dupe(u8, t);
}

pub fn run_read(sh: *Shell, argv: []const []const u8) Err!u8 {
    var raw = false;
    var silent = false;
    var arr_name: ?[]const u8 = null;
    var delim: u8 = '\n';
    var nchars: ?usize = null;
    var exact = false;
    var prompt: ?[]const u8 = null;
    var timeout: ?f64 = null;
    var fd: c_int = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'r' => raw = true,
                's' => silent = true,
                'e' => {},
                'a', 'd', 'i', 'n', 'N', 'p', 't', 'u' => {
                    var optarg: []const u8 = undefined;
                    if (j + 1 < a.len) {
                        optarg = a[j + 1 ..];
                        j = a.len;
                    } else {
                        i += 1;
                        if (i >= argv.len) {
                            sh.bmsg("read", "-{c}: option requires an argument", .{c});
                            sh.usage_msg("read", "read [-ers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]");
                            return 2;
                        }
                        optarg = argv[i];
                    }
                    switch (c) {
                        'a' => arr_name = optarg,
                        'd' => delim = if (optarg.len > 0) optarg[0] else 0,
                        'n', 'N' => {
                            const n = std.fmt.parseInt(i64, optarg, 10) catch {
                                sh.bmsg("read", "{s}: invalid number", .{optarg});
                                return 1;
                            };
                            nchars = if (n < 0) 0 else @intCast(n);
                            exact = c == 'N';
                        },
                        'p' => prompt = optarg,
                        't' => {
                            timeout = std.fmt.parseFloat(f64, optarg) catch {
                                sh.bmsg("read", "{s}: invalid timeout specification", .{optarg});
                                return 1;
                            };
                        },
                        'u' => {
                            fd = std.fmt.parseInt(c_int, optarg, 10) catch {
                                sh.bmsg("read", "{s}: invalid file descriptor specification", .{optarg});
                                return 1;
                            };
                        },
                        else => {},
                    }
                },
                else => {
                    sh.bmsg("read", "-{c}: invalid option", .{c});
                    sh.usage_msg("read", "read [-ers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]");
                    return 2;
                },
            }
        }
    }
    const names = argv[i..];
    for (names) |n| {
        if (!Shell.is_valid_name(n)) {
            if (std.mem.findScalar(u8, n, '[') != null and n[n.len - 1] == ']') continue;
            return invalid_ident(sh, n, "read");
        }
    }
    if (arr_name) |an| {
        if (!Shell.is_valid_name(an)) return invalid_ident(sh, an, "read");
    }
    if (sys.fcntl(fd, sys.F_GETFD) < 0) {
        sh.bmsg("read", "{d}: invalid file descriptor: Bad file descriptor", .{fd});
        return 1;
    }
    if (prompt) |p| {
        if (sys.isatty(fd) == 1) _ = sys.write_all(2, p);
    }
    var src = ByteSrc.init(fd);
    defer src.finish();
    if (timeout) |t| {
        if (t < 0) {
            sh.bmsg("read", "{d}: invalid timeout specification", .{t});
            return 1;
        }
        if (t == 0) {
            var pfd = [_]sys.PollFd{.{ .fd = fd, .events = sys.POLLIN, .revents = 0 }};
            const r = sys.poll(&pfd, 1, 0);
            return if (r > 0) 0 else 1;
        }
        src.deadline_ns = sys.mono_ns() + @as(i128, @intFromFloat(t * 1e9));
    }
    const a = sh.sa;
    var text: std.ArrayList(u8) = .empty;
    var esc: std.ArrayList(bool) = .empty;
    var got_delim = false;
    var count: usize = 0;
    var hit_eof = false;
    while (true) {
        if (nchars) |n| {
            if (count >= n) break;
        }
        const b = src.next() orelse {
            hit_eof = true;
            break;
        };
        if (!exact and b == delim) {
            got_delim = true;
            break;
        }
        if (b == '\\' and !raw and !exact) {
            const nb = src.next() orelse {
                hit_eof = true;
                break;
            };
            if (nb == '\n') continue;
            try text.append(a, nb);
            try esc.append(a, true);
            count += 1;
            continue;
        }
        try text.append(a, b);
        try esc.append(a, false);
        if (sh.utf8 and b >= 0xc0) {
            var need = strutil.seq_len(b, 4) - 1;
            while (need > 0) : (need -= 1) {
                const cb = src.next() orelse break;
                try text.append(a, cb);
                try esc.append(a, false);
            }
        }
        count += 1;
    }
    if (src.timed_out) {
        try assign_partial(sh, names, arr_name, text, esc);
        return 142;
    }
    const status: u8 = if (got_delim or (nchars != null and count >= nchars.? and !hit_eof) or (exact and count >= (nchars orelse 0))) 0 else 1;
    try assign_partial(sh, names, arr_name, text, esc);
    return status;
}

fn assign_partial(sh: *Shell, names: []const []const u8, arr_name: ?[]const u8, text: std.ArrayList(u8), esc: std.ArrayList(bool)) Err!void {
    const a = sh.sa;
    const rec: Rec = .{ .text = text.items, .esc = esc.items };
    const ifs = sh.ifs();
    if (arr_name) |an| {
        var fields: std.ArrayList([]const u8) = .empty;
        try split_fields(sh, rec, ifs, 0, true, &fields);
        const v = sh.find(an) orelse try sh.new_var(an);
        if (v.flags.readonly) return sh.readonly_err(v.name);
        try sh.declare_indexed(v);
        sh.clear_array(v);
        for (fields.items, 0..) |f, k| try sh.assign_indexed(v, @intCast(k), f, false);
        return;
    }
    if (names.len == 0) {
        try sh.assign_scalar("REPLY", text.items, false);
        return;
    }
    var fields: std.ArrayList([]const u8) = .empty;
    try split_fields(sh, rec, ifs, names.len, false, &fields);
    _ = a;
    for (names, 0..) |n, k| {
        const val: []const u8 = if (k < fields.items.len) fields.items[k] else "";
        if (std.mem.findScalar(u8, n, '[')) |lb| {
            if (n[n.len - 1] == ']') {
                try sh.assign_elem_text(n[0..lb], n[lb + 1 .. n.len - 1], val, false);
                continue;
            }
        }
        try sh.assign_scalar(n, val, false);
    }
}

pub fn run_mapfile(sh: *Shell, argv: []const []const u8) Err!u8 {
    var strip = false;
    var delim: u8 = '\n';
    var max: usize = 0;
    var origin: usize = 0;
    var skip: usize = 0;
    var fd: c_int = 0;
    var callback: ?[]const u8 = null;
    var quantum: usize = 5000;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                't' => strip = true,
                'd', 'n', 'O', 's', 'u', 'C', 'c' => {
                    var optarg: []const u8 = undefined;
                    if (j + 1 < a.len) {
                        optarg = a[j + 1 ..];
                        j = a.len;
                    } else {
                        i += 1;
                        if (i >= argv.len) {
                            sh.bmsg(argv[0], "-{c}: option requires an argument", .{c});
                            sh.usage_msg(argv[0], "mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]");
                            return 2;
                        }
                        optarg = argv[i];
                    }
                    switch (c) {
                        'd' => delim = if (optarg.len > 0) optarg[0] else 0,
                        'C' => callback = optarg,
                        else => {
                            const n = std.fmt.parseInt(i64, optarg, 10) catch {
                                const what: []const u8 = switch (c) {
                                    'n' => "line count",
                                    'O' => "array origin",
                                    's' => "line count",
                                    'u' => "file descriptor specification",
                                    else => "callback quantum",
                                };
                                sh.bmsg(argv[0], "{s}: invalid {s}", .{ optarg, what });
                                return 1;
                            };
                            if (c == 'u') fd = @intCast(n) else if (n < 0) {
                                sh.bmsg(argv[0], "{s}: invalid {s}", .{ optarg, if (c == 'O') "array origin" else "line count" });
                                return 1;
                            } else switch (c) {
                                'n' => max = @intCast(n),
                                'O' => origin = @intCast(n),
                                's' => skip = @intCast(n),
                                'c' => quantum = if (n == 0) 5000 else @intCast(n),
                                else => {},
                            }
                        },
                    }
                },
                else => {
                    sh.bmsg(argv[0], "-{c}: invalid option", .{c});
                    sh.usage_msg(argv[0], "mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]");
                    return 2;
                },
            }
        }
    }
    const name: []const u8 = if (i < argv.len) argv[i] else "MAPFILE";
    if (!Shell.is_valid_name(name)) return invalid_ident(sh, name, argv[0]);
    if (sys.fcntl(fd, sys.F_GETFD) < 0) {
        sh.bmsg(argv[0], "{d}: invalid file descriptor: Bad file descriptor", .{fd});
        return 1;
    }
    const v = sh.find(name) orelse try sh.new_var(name);
    if (v.flags.readonly) {
        sh.bmsg(argv[0], "{s}: readonly variable", .{name});
        return 1;
    }
    if (v.value == .assoc) {
        sh.bmsg(argv[0], "{s}: not an indexed array", .{name});
        return 1;
    }
    try sh.declare_indexed(v);
    if (origin == 0) sh.clear_array(v);
    var src = ByteSrc.init(fd);
    defer src.finish();
    const a = sh.sa;
    var idx: usize = origin;
    var lines_read: usize = 0;
    var stored: usize = 0;
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        line.clearRetainingCapacity();
        var got = false;
        var eof = false;
        while (true) {
            const b = src.next() orelse {
                eof = true;
                break;
            };
            if (b == delim) {
                got = true;
                break;
            }
            try line.append(a, b);
        }
        if (eof and line.items.len == 0) break;
        lines_read += 1;
        if (lines_read <= skip) {
            if (eof) break;
            continue;
        }
        if (!strip and got) try line.append(a, delim);
        const vv = sh.find(name).?;
        try sh.assign_indexed(vv, @intCast(idx), line.items, false);
        if (callback) |cb| {
            if (stored % quantum == quantum - 1 or quantum == 1) {
                const cmd = try std.fmt.allocPrint(a, "{s} {d} {s}", .{ cb, idx, try quote_arg(a, line.items) });
                const exec = @import("exec.zig");
                _ = try exec.run_string(sh, cmd, .{ .label = "", .line_base = 0 });
            }
        }
        idx += 1;
        stored += 1;
        if (max > 0 and stored >= max) break;
        if (eof) break;
    }
    return 0;
}

fn quote_arg(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try strutil.single_quote(a, &out, s);
    return out.items;
}

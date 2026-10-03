const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const strutil = @import("strutil.zig");
const Shell = shell.Shell;
const Err = shell.Err;

extern "c" fn snprintf(buf: ?[*]u8, n: usize, fmt: [*:0]const u8, ...) c_int;
extern "c" fn strtod(s: [*:0]const u8, end: *[*:0]const u8) f64;
extern "c" fn strftime(buf: [*]u8, max: usize, fmt: [*:0]const u8, tm: *const Tm) usize;
extern "c" fn localtime_r(t: *const i64, tm: *Tm) ?*Tm;

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

const Spec = struct {
    flags: [8]u8 = undefined,
    nflags: usize = 0,
    width: ?usize = null,
    prec: ?usize = null,
    star_width: bool = false,
    star_prec: bool = false,
};

const State = struct {
    sh: *Shell,
    args: []const []const u8,
    ai: usize = 0,
    status: u8 = 0,
    out: std.ArrayList(u8) = .empty,
    stop: bool = false,
    used_args: bool = false,
    name: []const u8 = "printf",

    fn next(self: *State) ?[]const u8 {
        if (self.ai < self.args.len) {
            const a = self.args[self.ai];
            self.ai += 1;
            self.used_args = true;
            return a;
        }
        return null;
    }
};

fn parse_int(st: *State, s: []const u8) i64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') {
        if (s.len > 1) {
            if (st.sh.utf8 and s[1] >= 0x80) {
                const l = strutil.seq_len(s[1], s.len - 1);
                if (std.unicode.utf8Decode(s[1 .. 1 + l])) |cp| return cp else |_| {}
            }
            return s[1];
        }
        return 0;
    }
    var i: usize = 0;
    var neg = false;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i < s.len and s[i] == '0' and i + 1 < s.len) {
        base = 8;
        i += 1;
    }
    var v: u64 = 0;
    var any = base == 8;
    var j = i;
    while (j < s.len) : (j += 1) {
        const d = std.fmt.charToDigit(s[j], base) catch break;
        v = v *% base +% d;
        any = true;
    }
    if (!any or j < s.len) {
        st.sh.bmsg(st.name, "{s}: invalid number", .{s});
        st.status = 1;
        if (!any) return 0;
    }
    const sv: i64 = @bitCast(v);
    return if (neg) 0 -% sv else sv;
}

fn parse_float(st: *State, s: []const u8) f64 {
    if (s.len == 0) return 0;
    if (s[0] == '\'' or s[0] == '"') return @floatFromInt(parse_int(st, s));
    const z = st.sh.sa.allocSentinel(u8, s.len, 0) catch return 0;
    @memcpy(z[0..s.len], s);
    var end: [*:0]const u8 = undefined;
    const v = strtod(z.ptr, &end);
    const consumed = @intFromPtr(end) - @intFromPtr(z.ptr);
    if (consumed == 0 or consumed < s.len) {
        const trailing_ws = blk: {
            var k = consumed;
            while (k < s.len and s[k] == ' ') k += 1;
            break :blk k == s.len and consumed > 0;
        };
        if (!trailing_ws) {
            st.sh.bmsg(st.name, "{s}: invalid number", .{s});
            st.status = 1;
        }
    }
    return v;
}

fn build_fmt(a: std.mem.Allocator, spec: Spec, width: ?usize, prec: ?usize, mod: []const u8, conv: u8) ![:0]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.append(a, '%');
    try b.appendSlice(a, spec.flags[0..spec.nflags]);
    if (width) |w| try b.print(a, "{d}", .{w});
    if (prec) |p| try b.print(a, ".{d}", .{p});
    try b.appendSlice(a, mod);
    try b.append(a, conv);
    return a.dupeZ(u8, b.items);
}

fn emit_formatted(st: *State, fmtz: [:0]const u8, comptime T: type, v: T) !void {
    const a = st.sh.sa;
    const n = snprintf(null, 0, fmtz.ptr, v);
    if (n < 0) return;
    const buf = try a.alloc(u8, @intCast(n + 1));
    _ = snprintf(buf.ptr, buf.len, fmtz.ptr, v);
    try st.out.appendSlice(a, buf[0..@intCast(n)]);
}

fn pad_str(st: *State, spec: Spec, width: ?usize, prec: ?usize, s_in: []const u8) !void {
    const a = st.sh.sa;
    var s = s_in;
    if (prec) |p| {
        if (p < s.len) s = s[0..p];
    }
    const len = s.len;
    const w = width orelse 0;
    const left = std.mem.findScalar(u8, spec.flags[0..spec.nflags], '-') != null;
    if (!left and w > len) try st.out.appendNTimes(a, ' ', w - len);
    try st.out.appendSlice(a, s);
    if (left and w > len) try st.out.appendNTimes(a, ' ', w - len);
}

fn do_escapes(st: *State, s: []const u8, out: *std.ArrayList(u8), stop_c: *bool, in_b: bool) !void {
    const a = st.sh.sa;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            try out.append(a, c);
            i += 1;
            continue;
        }
        const n = s[i + 1];
        if (n == 'c') {
            stop_c.* = true;
            return;
        }
        if (in_b and n == '0') {
            var v: u32 = 0;
            var k: usize = i + 2;
            var cnt: usize = 0;
            while (k < s.len and cnt < 3 and s[k] >= '0' and s[k] <= '7') : (k += 1) {
                v = v * 8 + (s[k] - '0');
                cnt += 1;
            }
            try out.append(a, @truncate(v));
            i = k;
            continue;
        }
        const r = try strutil.ansi_escape(a, out, s, i + 1, false);
        i += 1 + r.consumed;
    }
}

fn run_format(st: *State, fmt: []const u8) !void {
    const a = st.sh.sa;
    var i: usize = 0;
    while (i < fmt.len and !st.stop) {
        const c = fmt[i];
        if (c == '\\') {
            if (i + 1 < fmt.len and fmt[i + 1] == 'c') {
                st.stop = true;
                return;
            }
            if (i + 1 < fmt.len) {
                const r = try strutil.ansi_escape(a, &st.out, fmt, i + 1, false);
                i += 1 + r.consumed;
            } else {
                try st.out.append(a, '\\');
                i += 1;
            }
            continue;
        }
        if (c != '%') {
            try st.out.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) {
            try st.out.append(a, '%');
            break;
        }
        if (fmt[i] == '%') {
            try st.out.append(a, '%');
            i += 1;
            continue;
        }
        var spec: Spec = .{};
        while (i < fmt.len) : (i += 1) {
            const f = fmt[i];
            if (f == '-' or f == '+' or f == ' ' or f == '#' or f == '0' or f == '\'') {
                if (spec.nflags < spec.flags.len and f != '\'') {
                    spec.flags[spec.nflags] = f;
                    spec.nflags += 1;
                }
            } else break;
        }
        var width: ?usize = null;
        if (i < fmt.len and fmt[i] == '*') {
            const w = parse_int(st, st.next() orelse "0");
            if (w < 0) {
                if (spec.nflags < spec.flags.len) {
                    spec.flags[spec.nflags] = '-';
                    spec.nflags += 1;
                }
                width = @intCast(-w);
            } else width = @intCast(w);
            i += 1;
        } else {
            var w: usize = 0;
            var any = false;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
                w = w * 10 + (fmt[i] - '0');
                any = true;
            }
            if (any) width = w;
        }
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                const p = parse_int(st, st.next() orelse "0");
                prec = if (p < 0) null else @intCast(p);
                i += 1;
            } else {
                var p: usize = 0;
                while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) p = p * 10 + (fmt[i] - '0');
                prec = p;
            }
        }
        while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h' or fmt[i] == 'L' or fmt[i] == 'j' or fmt[i] == 'z' or fmt[i] == 't')) i += 1;
        if (i >= fmt.len) {
            st.sh.bmsg(st.name, "`%': missing format character", .{});
            st.status = 1;
            st.stop = true;
            return;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            'd', 'i' => {
                const v = parse_int(st, st.next() orelse "0");
                const f = try build_fmt(a, spec, width, prec, "ll", 'd');
                try emit_formatted(st, f, i64, v);
            },
            'u', 'o', 'x', 'X' => {
                const v = parse_int(st, st.next() orelse "0");
                const f = try build_fmt(a, spec, width, prec, "ll", conv);
                try emit_formatted(st, f, u64, @bitCast(v));
            },
            'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => {
                const v = parse_float(st, st.next() orelse "0");
                const f = try build_fmt(a, spec, width, prec, "", conv);
                try emit_formatted(st, f, f64, v);
            },
            'c' => {
                const arg = st.next() orelse "";
                if (arg.len == 0) {
                    try pad_str(st, spec, width, null, "");
                } else {
                    try pad_str(st, spec, width, null, arg[0..1]);
                }
            },
            's' => {
                const arg = st.next() orelse "";
                try pad_str(st, spec, width, prec, arg);
            },
            'b' => {
                const arg = st.next() orelse "";
                var tmp: std.ArrayList(u8) = .empty;
                var stop = false;
                try do_escapes(st, arg, &tmp, &stop, true);
                try pad_str(st, spec, width, prec, tmp.items);
                if (stop) {
                    st.stop = true;
                    return;
                }
            },
            'q' => {
                const arg = st.next() orelse "";
                var tmp: std.ArrayList(u8) = .empty;
                try strutil.quote_printf_q(a, &tmp, arg);
                try pad_str(st, spec, width, prec, tmp.items);
            },
            '(' => {
                const close = std.mem.findScalarPos(u8, fmt, i, ')') orelse {
                    st.sh.bmsg(st.name, "`(': missing format character", .{});
                    st.status = 1;
                    st.stop = true;
                    return;
                };
                const tf = fmt[i..close];
                i = close + 1;
                if (i < fmt.len and fmt[i] == 'T') i += 1;
                const arg = st.next() orelse "-1";
                var t: i64 = parse_int(st, arg);
                if (t == -1) t = @intCast(@divTrunc(sys.now_ns(), 1_000_000_000));
                if (t == -2) t = @intCast(@divTrunc(st.sh.start_wall_ns, 1_000_000_000));
                var tm: Tm = undefined;
                _ = localtime_r(&t, &tm);
                const fz = try a.dupeZ(u8, tf);
                var buf: [512]u8 = undefined;
                const n = strftime(&buf, buf.len, fz.ptr, &tm);
                try pad_str(st, spec, width, prec, buf[0..n]);
            },
            else => {
                st.sh.bmsg(st.name, "`{c}': invalid format character", .{conv});
                st.status = 1;
                st.stop = true;
                return;
            },
        }
    }
}

pub fn run(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var vname: ?[]const u8 = null;
    while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-v")) {
            if (i + 1 >= argv.len) {
                sh.bmsg("printf", "-v: option requires an argument", .{});
                sh.usage_msg("printf", "printf [-v var] format [arguments]");
                return 2;
            }
            vname = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (a.len > 1 and a[0] == '-' and a[1] != '-' and !std.ascii.isDigit(a[1]) and !std.mem.eql(u8, a, "-")) {
            sh.bmsg("printf", "{s}: invalid option", .{a});
            sh.usage_msg("printf", "printf [-v var] format [arguments]");
            return 2;
        } else break;
    }
    if (i >= argv.len) {
        sh.usage_msg("printf", "printf [-v var] format [arguments]");
        return 2;
    }
    const fmt = argv[i];
    const args = argv[i + 1 ..];
    var st: State = .{ .sh = sh, .args = args };
    while (true) {
        st.used_args = false;
        const start_ai = st.ai;
        try run_format(&st, fmt);
        if (st.stop) break;
        if (st.ai >= args.len or st.ai == start_ai) break;
    }
    if (vname) |vn| {
        if (std.mem.findScalar(u8, vn, '[')) |lb| {
            if (vn[vn.len - 1] == ']') {
                try sh.assign_elem_text(vn[0..lb], vn[lb + 1 .. vn.len - 1], st.out.items, false);
                return st.status;
            }
        }
        if (!Shell.is_valid_name(vn)) {
            sh.bmsg("printf", "`{s}': not a valid identifier", .{vn});
            return 2;
        }
        try sh.assign_scalar(vn, st.out.items, false);
    } else if (st.out.items.len > 0) {
        if (!sh.out(st.out.items)) {
            sh.bmsg("printf", "write error: {s}", .{sys.msg_for(sys.errno())});
            return 1;
        }
    }
    return st.status;
}

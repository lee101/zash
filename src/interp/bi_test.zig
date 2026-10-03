const std = @import("std");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const testops = @import("testops.zig");
const cond = @import("cond.zig");
const Shell = shell.Shell;
const Err = shell.Err;

const T = struct {
    sh: *Shell,
    name: []const u8,
    args: []const []const u8,
    pos: usize = 0,
    failed: bool = false,

    fn fail(self: *T, comptime fmt: []const u8, a: anytype) void {
        if (!self.failed) self.sh.bmsg(self.name, fmt, a);
        self.failed = true;
    }

    fn peek(self: *T) ?[]const u8 {
        return if (self.pos < self.args.len) self.args[self.pos] else null;
    }
};

fn is_unary(s: []const u8) bool {
    if (s.len != 2 or s[0] != '-') return false;
    return std.mem.findScalar(u8, "abcdefghknoprstuvwxzGLNORS", s[1]) != null;
}

fn is_binary(s: []const u8) bool {
    const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef" };
    for (ops) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn parse_int(t: *T, s: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, s, " \t\n");
    const v = std.fmt.parseInt(i64, trimmed, 10) catch {
        t.fail("{s}: integer expression expected", .{s});
        return null;
    };
    return v;
}

fn unary(t: *T, op: []const u8, arg: []const u8) Err!bool {
    switch (op[1]) {
        'z' => return arg.len == 0,
        'n' => return arg.len > 0,
        'o' => {
            for (shell.opt_names, 0..) |n, i| if (std.mem.eql(u8, n, arg)) return t.sh.opts[i];
            return false;
        },
        'v' => return cond.var_is_set(t.sh, arg),
        'R' => {
            const v = t.sh.vars.get(arg) orelse return false;
            return v.flags.nameref and v.is_set();
        },
        else => return testops.file_unary(op[1], arg),
    }
}

fn binary(t: *T, l: []const u8, op: []const u8, r: []const u8) bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, l, r);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, l, r);
    if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, l, r) == .lt;
    if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, l, r) == .gt;
    if (std.mem.eql(u8, op, "-nt")) return testops.newer(l, r);
    if (std.mem.eql(u8, op, "-ot")) return testops.older(l, r);
    if (std.mem.eql(u8, op, "-ef")) return testops.same_file(l, r);
    const a = parse_int(t, l) orelse return false;
    const b = parse_int(t, r) orelse return false;
    if (std.mem.eql(u8, op, "-eq")) return a == b;
    if (std.mem.eql(u8, op, "-ne")) return a != b;
    if (std.mem.eql(u8, op, "-lt")) return a < b;
    if (std.mem.eql(u8, op, "-le")) return a <= b;
    if (std.mem.eql(u8, op, "-gt")) return a > b;
    return a >= b;
}

fn parse_or(t: *T) Err!bool {
    var l = try parse_and(t);
    while (t.peek()) |tok| {
        if (!std.mem.eql(u8, tok, "-o")) break;
        t.pos += 1;
        const r = try parse_and(t);
        l = l or r;
    }
    return l;
}

fn parse_and(t: *T) Err!bool {
    var l = try parse_not(t);
    while (t.peek()) |tok| {
        if (!std.mem.eql(u8, tok, "-a")) break;
        t.pos += 1;
        const r = try parse_not(t);
        l = l and r;
    }
    return l;
}

fn parse_not(t: *T) Err!bool {
    if (t.peek()) |tok| {
        if (std.mem.eql(u8, tok, "!")) {
            t.pos += 1;
            return !(try parse_not(t));
        }
    }
    return parse_primary(t);
}

fn parse_primary(t: *T) Err!bool {
    const tok = t.peek() orelse {
        t.fail("argument expected", .{});
        return false;
    };
    if (std.mem.eql(u8, tok, "(")) {
        t.pos += 1;
        const v = try parse_or(t);
        if (t.peek()) |c| {
            if (std.mem.eql(u8, c, ")")) {
                t.pos += 1;
                return v;
            }
        }
        t.fail("`)' expected", .{});
        return false;
    }
    const remaining = t.args.len - t.pos;
    if (remaining >= 3 and is_binary(t.args[t.pos + 1])) {
        const l = t.args[t.pos];
        const op = t.args[t.pos + 1];
        const r = t.args[t.pos + 2];
        t.pos += 3;
        return binary(t, l, op, r);
    }
    if (remaining >= 2 and is_unary(tok)) {
        const arg = t.args[t.pos + 1];
        t.pos += 2;
        return unary(t, tok, arg);
    }
    t.pos += 1;
    return tok.len > 0;
}

fn eval_args(t: *T, args: []const []const u8) Err!bool {
    const sh = t.sh;
    const name = t.name;
    const n = args.len;
    switch (n) {
        0 => return false,
        1 => return args[0].len > 0,
        2 => {
            if (std.mem.eql(u8, args[0], "!")) return args[1].len == 0;
            if (is_unary(args[0])) return unary(t, args[0], args[1]);
            sh.bmsg(name, "{s}: unary operator expected", .{args[0]});
            t.failed = true;
            return false;
        },
        3 => {
            if (is_binary(args[1])) return binary(t, args[0], args[1], args[2]);
            if (std.mem.eql(u8, args[0], "!")) return !(try eval_args(t, args[1..]));
            if (std.mem.eql(u8, args[0], "(") and std.mem.eql(u8, args[2], ")")) return args[1].len > 0;
            if (std.mem.eql(u8, args[1], "-a")) return args[0].len > 0 and args[2].len > 0;
            if (std.mem.eql(u8, args[1], "-o")) return args[0].len > 0 or args[2].len > 0;
            sh.bmsg(name, "{s}: binary operator expected", .{args[1]});
            t.failed = true;
            return false;
        },
        4 => {
            if (std.mem.eql(u8, args[0], "!")) return !(try eval_args(t, args[1..]));
            if (std.mem.eql(u8, args[0], "(") and std.mem.eql(u8, args[3], ")")) return eval_args(t, args[1..3]);
        },
        else => {},
    }
    t.args = args;
    t.pos = 0;
    const r = try parse_or(t);
    if (!t.failed and t.pos < args.len) t.fail("too many arguments", .{});
    return r;
}

pub fn run(sh: *Shell, argv: []const []const u8) Err!u8 {
    const is_br = std.mem.eql(u8, argv[0], "[");
    var args = argv[1..];
    var t: T = .{ .sh = sh, .name = argv[0], .args = args };
    if (is_br) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            sh.bmsg("[", "missing `]'", .{});
            return 2;
        }
        args = args[0 .. args.len - 1];
        t.args = args;
    }
    const result = try eval_args(&t, args);
    if (t.failed) return 2;
    return if (result) 0 else 1;
}

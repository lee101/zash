const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const arith = @import("arith.zig");
const pattern = @import("pattern.zig");
const testops = @import("testops.zig");
const Shell = shell.Shell;
const Err = shell.Err;

pub const CondErr = Err;

fn opt_enabled(sh: *Shell, name: []const u8) bool {
    for (shell.opt_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return sh.opts[i];
    }
    return false;
}

pub fn var_is_set(sh: *Shell, text: []const u8) Err!bool {
    if (std.mem.findScalar(u8, text, '[')) |lb| {
        if (text[text.len - 1] == ']') {
            const name = text[0..lb];
            const sub = text[lb + 1 .. text.len - 1];
            const v = sh.find(name) orelse return false;
            switch (v.value) {
                .assoc => |*m| return m.get(sub) != null,
                .indexed => |*ix| {
                    if (std.mem.eql(u8, sub, "@") or std.mem.eql(u8, sub, "*")) return ix.items.items.len > 0;
                    var idx = try sh.eval_int(sub);
                    if (idx < 0) idx += ix.max_index() + 1;
                    return ix.get(idx) != null;
                },
                .str => return (try sh.eval_int(sub)) == 0,
                .none => return false,
            }
        }
    }
    if (text.len > 0 and (std.ascii.isDigit(text[0]))) {
        const n = std.fmt.parseInt(usize, text, 10) catch return false;
        if (n == 0) return true;
        return n <= sh.pos.items.len;
    }
    if (text.len == 1) switch (text[0]) {
        '@', '*' => return sh.pos.items.len > 0,
        '#', '?', '$', '-' => return true,
        '!' => return sh.last_bg != 0,
        else => {},
    };
    const v = sh.find(text) orelse return false;
    if (v.special != .none) return true;
    return v.is_set();
}

fn regex_escape(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\', '.', '[', ']', '(', ')', '*', '+', '?', '{', '}', '|', '^', '$' => try out.append(a, '\\'),
            else => {},
        }
        try out.append(a, c);
    }
}

fn word_regex(sh: *Shell, w: ast.Word) Err![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (w.parts) |p| {
        const single = [_]ast.Part{p};
        const text = try expand.word_string(sh, .{ .parts = &single, .line = w.line });
        switch (p) {
            .quoted, .dquote, .ansi_c => try regex_escape(sh.sa, &out, text),
            else => try out.appendSlice(sh.sa, text),
        }
    }
    return out.items;
}

fn do_regex(sh: *Shell, text: []const u8, rx: []const u8) Err!u8 {
    var re: sys.Regex = .{};
    const rz = try sh.sa.allocSentinel(u8, rx.len, 0);
    @memcpy(rz[0..rx.len], rx);
    var cflags: c_int = 1;
    if (sh.shopt(.nocasematch)) cflags |= 2;
    const rc = sys.regcomp(&re, rz.ptr, cflags);
    if (rc != 0) return 2;
    defer sys.regfree(&re);
    const nsub = std.mem.readInt(usize, re.buf[48..56], .little);
    const nmatch = @min(nsub + 1, 64);
    var matches: [64]sys.RegMatch = undefined;
    const tz = try sh.sa.allocSentinel(u8, text.len, 0);
    @memcpy(tz[0..text.len], text);
    const er = sys.regexec(&re, tz.ptr, nmatch, &matches, 0);
    const v = sh.find("BASH_REMATCH") orelse try sh.new_var("BASH_REMATCH");
    try sh.declare_indexed(v);
    sh.clear_array(v);
    if (er != 0) return 1;
    var i: usize = 0;
    while (i < nmatch) : (i += 1) {
        const m = matches[i];
        const s: []const u8 = if (m.so < 0) "" else text[@intCast(m.so)..@intCast(m.eo)];
        try sh.assign_indexed(v, @intCast(i), s, false);
    }
    return 0;
}

pub fn eval(sh: *Shell, c: *const ast.Cond) CondErr!bool {
    switch (c.*) {
        .word => |w| {
            const s = try expand.word_string(sh, w);
            return s.len > 0;
        },
        .not => |n| return !(try eval(sh, n)),
        .and_ => |a| {
            if (!try eval(sh, a.lhs)) return false;
            return eval(sh, a.rhs);
        },
        .or_ => |a| {
            if (try eval(sh, a.lhs)) return true;
            return eval(sh, a.rhs);
        },
        .group => |g| return eval(sh, g),
        .unary => |u| {
            const s = try expand.word_string(sh, u.arg);
            return switch (u.op) {
                .z => s.len == 0,
                .n => s.len > 0,
                .o => opt_enabled(sh, s),
                .v => try var_is_set(sh, s),
                .R => blk: {
                    const v = sh.vars.get(s) orelse break :blk false;
                    break :blk v.flags.nameref and v.is_set();
                },
                .a => testops.file_unary('e', s),
                .b => testops.file_unary('b', s),
                .c => testops.file_unary('c', s),
                .d => testops.file_unary('d', s),
                .e => testops.file_unary('e', s),
                .f => testops.file_unary('f', s),
                .g => testops.file_unary('g', s),
                .h => testops.file_unary('h', s),
                .k => testops.file_unary('k', s),
                .p => testops.file_unary('p', s),
                .r => testops.file_unary('r', s),
                .s => testops.file_unary('s', s),
                .t => testops.file_unary('t', s),
                .u => testops.file_unary('u', s),
                .w => testops.file_unary('w', s),
                .x => testops.file_unary('x', s),
                .G => testops.file_unary('G', s),
                .L => testops.file_unary('L', s),
                .N => testops.file_unary('N', s),
                .O => testops.file_unary('O', s),
                .S => testops.file_unary('S', s),
            };
        },
        .binary => |b| {
            switch (b.op) {
                .eq, .eq2, .ne => {
                    const l = try expand.word_string(sh, b.lhs);
                    const pat = try expand.word_pattern(sh, b.rhs);
                    const m = pattern.match(sh.sa, pat, l, .{ .extglob = true, .nocase = sh.shopt(.nocasematch) });
                    return if (b.op == .ne) !m else m;
                },
                .match => {
                    const l = try expand.word_string(sh, b.lhs);
                    const rx = try word_regex(sh, b.rhs);
                    const r = try do_regex(sh, l, rx);
                    if (r == 2) {
                        sh.status = 2;
                        return error.ArithError;
                    }
                    return r == 0;
                },
                .lt => {
                    const l = try expand.word_string(sh, b.lhs);
                    const r = try expand.word_string(sh, b.rhs);
                    return std.mem.order(u8, l, r) == .lt;
                },
                .gt => {
                    const l = try expand.word_string(sh, b.lhs);
                    const r = try expand.word_string(sh, b.rhs);
                    return std.mem.order(u8, l, r) == .gt;
                },
                .int_eq, .int_ne, .int_lt, .int_le, .int_gt, .int_ge => {
                    const ls = try expand.word_string(sh, b.lhs);
                    const rs = try expand.word_string(sh, b.rhs);
                    const l = try arith.to_int(sh, ls, .command);
                    const r = try arith.to_int(sh, rs, .command);
                    return switch (b.op) {
                        .int_eq => l == r,
                        .int_ne => l != r,
                        .int_lt => l < r,
                        .int_le => l <= r,
                        .int_gt => l > r,
                        .int_ge => l >= r,
                        else => unreachable,
                    };
                },
                .nt, .ot, .ef => {
                    const l = try expand.word_string(sh, b.lhs);
                    const r = try expand.word_string(sh, b.rhs);
                    return switch (b.op) {
                        .nt => testops.newer(l, r),
                        .ot => testops.older(l, r),
                        else => testops.same_file(l, r),
                    };
                },
            }
        },
    }
}

pub fn trace(sh: *Shell, c: *const ast.Cond, w: *std.ArrayList(u8)) Err!void {
    const a = sh.sa;
    switch (c.*) {
        .word => |wd| try w.appendSlice(a, try expand.word_string(sh, wd)),
        .not => |n| {
            try w.appendSlice(a, "! ");
            try trace(sh, n, w);
        },
        .and_ => |x| {
            try trace(sh, x.lhs, w);
            try w.appendSlice(a, " && ");
            try trace(sh, x.rhs, w);
        },
        .or_ => |x| {
            try trace(sh, x.lhs, w);
            try w.appendSlice(a, " || ");
            try trace(sh, x.rhs, w);
        },
        .group => |g| try trace(sh, g, w),
        .unary => |u| {
            try w.appendSlice(a, "-");
            try w.appendSlice(a, @tagName(u.op));
            try w.append(a, ' ');
            try w.appendSlice(a, try expand.word_string(sh, u.arg));
        },
        .binary => |b| {
            try w.appendSlice(a, try expand.word_string(sh, b.lhs));
            try w.append(a, ' ');
            try w.appendSlice(a, switch (b.op) {
                .eq => "=",
                .eq2 => "==",
                .ne => "!=",
                .match => "=~",
                .lt => "<",
                .gt => ">",
                .int_eq => "-eq",
                .int_ne => "-ne",
                .int_lt => "-lt",
                .int_le => "-le",
                .int_gt => "-gt",
                .int_ge => "-ge",
                .nt => "-nt",
                .ot => "-ot",
                .ef => "-ef",
            });
            try w.append(a, ' ');
            try w.appendSlice(a, try expand.word_string(sh, b.rhs));
        },
    }
}

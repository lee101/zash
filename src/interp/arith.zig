const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const Shell = shell.Shell;
const Err = shell.Err;

pub const Ctx = enum { expansion, command, let };

var depth: u32 = 0;

fn fail(sh: *Shell, comptime fmt: []const u8, args: anytype) Err {
    sh.msg(fmt, args);
    return error.ArithError;
}

pub fn render(sh: *Shell, node: *const ast.Arith, out: *std.ArrayList(u8)) Err!void {
    const a = sh.sa;
    switch (node.*) {
        .num => |n| try out.print(a, "{d}", .{n}),
        .bad_num => |t| try out.appendSlice(a, t),
        .variable => |v| {
            try out.appendSlice(a, v.name);
            if (v.raw_index.len > 0) try out.print(a, "[{s}]", .{v.raw_index});
        },
        .expansion => |w| try out.appendSlice(a, try expand.word_string(sh, w)),
        .unary => |u| {
            try out.appendSlice(a, switch (u.op) {
                .neg => "-",
                .plus => "+",
                .log_not => "!",
                .bit_not => "~",
            });
            try render(sh, u.operand, out);
        },
        .incdec => |i| {
            const pre = i.kind == .pre_inc or i.kind == .pre_dec;
            const op: []const u8 = if (i.kind == .pre_inc or i.kind == .post_inc) "++" else "--";
            if (pre) try out.appendSlice(a, op);
            try render(sh, i.target, out);
            if (!pre) try out.appendSlice(a, op);
        },
        .binary => |b| {
            try render(sh, b.lhs, out);
            try out.appendSlice(a, binop_text(b.op));
            try render(sh, b.rhs, out);
        },
        .assign => |s| {
            try render(sh, s.target, out);
            if (s.op) |o| try out.appendSlice(a, binop_text(o));
            try out.append(a, '=');
            try render(sh, s.value, out);
        },
        .ternary => |t| {
            try render(sh, t.cond, out);
            try out.append(a, '?');
            try render(sh, t.then, out);
            try out.append(a, ':');
            try render(sh, t.otherwise, out);
        },
        .comma => |c| {
            try render(sh, c.lhs, out);
            try out.append(a, ',');
            try render(sh, c.rhs, out);
        },
        .invalid => |i| try out.appendSlice(a, i.expr),
    }
}

fn binop_text(op: ast.BinOp) []const u8 {
    return switch (op) {
        .mul => "*",
        .div => "/",
        .mod => "%",
        .add => "+",
        .sub => "-",
        .shl => "<<",
        .shr => ">>",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .eq => "==",
        .ne => "!=",
        .bit_and => "&",
        .bit_xor => "^",
        .bit_or => "|",
        .log_and => "&&",
        .log_or => "||",
        .pow => "**",
    };
}

const Eval = struct {
    sh: *Shell,
    root: *const ast.Arith,
    ctx: Ctx,
    src: []const u8,

    fn err(self: *Eval, comptime what: []const u8, tok: *const ast.Arith) Err {
        const sh = self.sh;
        var full: std.ArrayList(u8) = .empty;
        if (self.src.len > 0) {
            full.appendSlice(sh.sa, self.src) catch {};
        } else render(sh, self.root, &full) catch {};
        var t: std.ArrayList(u8) = .empty;
        var tn = tok;
        while (tn.* == .unary) tn = tn.unary.operand;
        render(sh, tn, &t) catch {};
        switch (self.ctx) {
            .expansion => sh.msg("{s}: " ++ what ++ " (error token is \"{s}\")", .{ full.items, t.items }),
            .command => sh.msg("((: {s}: " ++ what ++ " (error token is \"{s}\")", .{ full.items, t.items }),
            .let => sh.msg("let: {s}: " ++ what ++ " (error token is \"{s}\")", .{ full.items, t.items }),
        }
        return error.ArithError;
    }

    fn var_value(self: *Eval, v: ast.ArithVar) Err!i64 {
        const sh = self.sh;
        const text = try self.var_text(v);
        const t = text orelse return 0;
        return to_int(sh, t, self.ctx);
    }

    fn var_text(self: *Eval, v: ast.ArithVar) Err!?[]const u8 {
        const sh = self.sh;
        const found = sh.find(v.name);
        if (v.index != null or v.raw_index.len > 0) {
            const var_ = found orelse return null;
            switch (var_.value) {
                .assoc => |*m| {
                    const key = try expand.subscript_text(sh, v.raw_index);
                    return m.get(key);
                },
                .indexed => |*ix| {
                    var idx = try self.eval(v.index.?);
                    if (idx < 0) idx += ix.max_index() + 1;
                    return ix.get(idx);
                },
                .str => |s| {
                    const idx = try self.eval(v.index.?);
                    return if (idx == 0) s else null;
                },
                .none => return null,
            }
        }
        if (found) |f| return sh.scalar_of(f);
        if (std.mem.eql(u8, v.name, "RANDOM") or std.mem.eql(u8, v.name, "LINENO")) return null;
        if (sh.opt(.nounset) and v.name.len > 0) {
            sh.msg("{s}: unbound variable", .{v.name});
            sh.status = sh.fatal_status();
            return error.Exit;
        }
        return null;
    }

    fn store(self: *Eval, v: ast.ArithVar, val: i64) Err!void {
        const sh = self.sh;
        const text = try sh.tmp_fmt("{d}", .{val});
        if (v.index != null or v.raw_index.len > 0) {
            const var_ = sh.find(v.name) orelse try sh.new_var(v.name);
            if (var_.flags.readonly) return sh.readonly_err(var_.name);
            if (var_.value == .assoc) {
                const key = try expand.subscript_text(sh, v.raw_index);
                return sh.assign_assoc(var_, key, text, false);
            }
            const idx = try self.eval(v.index.?);
            return sh.assign_indexed(var_, idx, text, false);
        }
        return sh.assign_scalar(v.name, text, false);
    }

    fn eval(self: *Eval, node: *const ast.Arith) Err!i64 {
        switch (node.*) {
            .num => |n| return n,
            .bad_num => |t| {
                const sh = self.sh;
                var full: std.ArrayList(u8) = .empty;
                if (self.src.len > 0) full.appendSlice(sh.sa, self.src) catch {} else render(sh, self.root, &full) catch {};
                switch (self.ctx) {
                    .expansion => sh.msg("{s}: value too great for base (error token is \"{s}\")", .{ full.items, t }),
                    .command => sh.msg("((: {s}: value too great for base (error token is \"{s}\")", .{ full.items, t }),
                    .let => sh.msg("let: {s}: value too great for base (error token is \"{s}\")", .{ full.items, t }),
                }
                return error.ArithError;
            },
            .invalid => |i| {
                const sh = self.sh;
                var msg_text: []const u8 = i.msg;
                const tail = "(error token is \"\")";
                if (std.mem.endsWith(u8, msg_text, tail)) {
                    const trimmed = std.mem.trimEnd(u8, i.expr, " \t\n");
                    var k = trimmed.len;
                    while (k > 0 and std.mem.findScalar(u8, "+-*/%&|^<>=!?:~,", trimmed[k - 1]) != null) k -= 1;
                    if (k < trimmed.len) {
                        msg_text = std.fmt.allocPrint(sh.sa, "{s}(error token is \"{s}\")", .{ msg_text[0 .. msg_text.len - tail.len], trimmed[k..] }) catch msg_text;
                    }
                }
                switch (self.ctx) {
                    .expansion => sh.msg("{s}: {s}", .{ i.expr, msg_text }),
                    .command => sh.msg("((: {s}: {s}", .{ i.expr, msg_text }),
                    .let => sh.msg("let: {s}: {s}", .{ i.expr, msg_text }),
                }
                return error.ArithError;
            },
            .variable => |v| return self.var_value(v),
            .expansion => |w| {
                const text = try expand.word_string(self.sh, w);
                return to_int(self.sh, text, self.ctx);
            },
            .unary => |u| {
                const x = try self.eval(u.operand);
                return switch (u.op) {
                    .neg => 0 -% x,
                    .plus => x,
                    .log_not => @intFromBool(x == 0),
                    .bit_not => ~x,
                };
            },
            .incdec => |i| {
                const target = i.target;
                if (target.* != .variable) return self.err("attempted assignment to non-variable", target);
                const old = try self.var_value(target.variable);
                const new = switch (i.kind) {
                    .pre_inc, .post_inc => old +% 1,
                    .pre_dec, .post_dec => old -% 1,
                };
                try self.store(target.variable, new);
                return switch (i.kind) {
                    .pre_inc, .pre_dec => new,
                    .post_inc, .post_dec => old,
                };
            },
            .binary => |b| return self.binary(b.op, b.lhs, b.rhs),
            .assign => |s| {
                const target = s.target;
                if (target.* != .variable) return self.err("attempted assignment to non-variable", target);
                var val: i64 = undefined;
                if (s.op) |op| {
                    const old = try self.var_value(target.variable);
                    const r = try self.eval(s.value);
                    val = try self.apply(op, old, r, s.value);
                } else {
                    val = try self.eval(s.value);
                }
                try self.store(target.variable, val);
                return val;
            },
            .ternary => |t| {
                const c = try self.eval(t.cond);
                if (c != 0) return self.eval(t.then);
                return self.eval(t.otherwise);
            },
            .comma => |c| {
                _ = try self.eval(c.lhs);
                return self.eval(c.rhs);
            },
        }
    }

    fn binary(self: *Eval, op: ast.BinOp, lhs: *const ast.Arith, rhs: *const ast.Arith) Err!i64 {
        switch (op) {
            .log_and => {
                const l = try self.eval(lhs);
                if (l == 0) return 0;
                return @intFromBool((try self.eval(rhs)) != 0);
            },
            .log_or => {
                const l = try self.eval(lhs);
                if (l != 0) return 1;
                return @intFromBool((try self.eval(rhs)) != 0);
            },
            else => {},
        }
        const l = try self.eval(lhs);
        const r = try self.eval(rhs);
        return self.apply(op, l, r, rhs);
    }

    fn apply(self: *Eval, op: ast.BinOp, l: i64, r: i64, rhs: *const ast.Arith) Err!i64 {
        return switch (op) {
            .add => l +% r,
            .sub => l -% r,
            .mul => l *% r,
            .div => blk: {
                if (r == 0) return self.err("division by 0", rhs);
                if (l == std.math.minInt(i64) and r == -1) break :blk l;
                break :blk @divTrunc(l, r);
            },
            .mod => blk: {
                if (r == 0) return self.err("division by 0", rhs);
                if (r == -1) break :blk 0;
                break :blk @rem(l, r);
            },
            .shl => l << @intCast(@as(u64, @bitCast(r)) & 63),
            .shr => l >> @intCast(@as(u64, @bitCast(r)) & 63),
            .lt => @intFromBool(l < r),
            .le => @intFromBool(l <= r),
            .gt => @intFromBool(l > r),
            .ge => @intFromBool(l >= r),
            .eq => @intFromBool(l == r),
            .ne => @intFromBool(l != r),
            .bit_and => l & r,
            .bit_xor => l ^ r,
            .bit_or => l | r,
            .log_and => @intFromBool(l != 0 and r != 0),
            .log_or => @intFromBool(l != 0 or r != 0),
            .pow => blk: {
                if (r < 0) return self.err("exponent less than 0", rhs);
                var result: i64 = 1;
                var base = l;
                var e: u64 = @intCast(r);
                while (e > 0) : (e >>= 1) {
                    if (e & 1 == 1) result *%= base;
                    base *%= base;
                }
                break :blk result;
            },
        };
    }
};

pub fn eval_node(sh: *Shell, node: *const ast.Arith, ctx: Ctx, src: []const u8) Err!i64 {
    var e: Eval = .{ .sh = sh, .root = node, .ctx = ctx, .src = src };
    return e.eval(node);
}

fn fast_int(t: []const u8) ?i64 {
    if (t.len == 0 or t.len > 18) return null;
    var i: usize = 0;
    var neg = false;
    if (t[0] == '-') {
        neg = true;
        i = 1;
        if (t.len == 1) return null;
    }
    if (t[i] == '0' and t.len > i + 1) return null;
    var v: i64 = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return if (neg) -v else v;
}

pub fn to_int(sh: *Shell, text: []const u8, ctx: Ctx) Err!i64 {
    if (fast_int(text)) |v| return v;
    const t = std.mem.trim(u8, text, " \t\n");
    if (t.len == 0) return 0;
    if (fast_int(t)) |v| return v;
    return eval_string_ctx(sh, t, ctx);
}

pub fn eval_string(sh: *Shell, text: []const u8) Err!i64 {
    return to_int(sh, text, .expansion) catch |e| switch (e) {
        error.ArithError => {
            sh.status = 1;
            return error.Abort;
        },
        else => return e,
    };
}

pub fn eval_string_ctx(sh: *Shell, text: []const u8, ctx: Ctx) Err!i64 {
    if (depth > 32) {
        sh.msg("{s}: expression recursion level exceeded (error token is \"{s}\")", .{ text, text });
        return error.ArithError;
    }
    depth += 1;
    defer depth -= 1;
    const node = parser.parse_arith_text(sh.sa, text) catch return error.OutOfMemory;
    return eval_node(sh, node, ctx, text);
}

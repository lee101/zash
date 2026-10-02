const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Lexer = lexer.Lexer;
const Allocator = std.mem.Allocator;

const AErr = error{ ArithSyntax, Syntax, OutOfMemory };

const max_nodes: u32 = 10000;

const BinInfo = struct { op: ast.BinOp, len: u8, prec: u8 };
const AssignInfo = struct { op: ?ast.BinOp, len: u8 };

const A = struct {
    lx: *Lexer,
    msg: []const u8 = "",
    nodes: u32 = 0,

    fn arena(self: *A) Allocator {
        return self.lx.arena;
    }

    fn alloc_node(self: *A, v: ast.Arith) Allocator.Error!*const ast.Arith {
        const n = try self.arena().create(ast.Arith);
        n.* = v;
        return n;
    }

    fn mk(self: *A, v: ast.Arith) AErr!*const ast.Arith {
        self.nodes += 1;
        if (self.nodes > max_nodes) {
            self.msg = "expression too complex";
            return error.ArithSyntax;
        }
        return self.alloc_node(v);
    }

    fn ws(self: *A) void {
        const lx = self.lx;
        while (lx.pos < lx.src.len) : (lx.pos += 1) {
            switch (lx.src[lx.pos]) {
                ' ', '\t', '\n' => {},
                else => break,
            }
        }
    }

    fn at(self: *A, off: usize) u8 {
        const i = self.lx.pos + off;
        return if (i < self.lx.src.len) self.lx.src[i] else 0;
    }

    fn fail(self: *A, comptime what: []const u8) AErr {
        const rest = std.mem.trim(u8, self.lx.src[@min(self.lx.pos, self.lx.src.len)..], " \t\n");
        self.msg = std.fmt.allocPrint(self.arena(), what ++ " (error token is \"{s}\")", .{rest}) catch "syntax error";
        return error.ArithSyntax;
    }

    fn enter(self: *A) AErr!void {
        self.lx.depth += 1;
        if (self.lx.depth > lexer.max_depth) return self.lx.fail_nesting();
    }

    fn leave(self: *A) void {
        self.lx.depth -= 1;
    }

    fn parse_comma(self: *A) AErr!*const ast.Arith {
        var l = try self.parse_assign();
        while (true) {
            self.ws();
            if (self.at(0) != ',') break;
            self.lx.pos += 1;
            const r = try self.parse_assign();
            l = try self.mk(.{ .comma = .{ .lhs = l, .rhs = r } });
        }
        return l;
    }

    fn assign_op(self: *A) ?AssignInfo {
        const c = self.at(0);
        const c1 = self.at(1);
        const c2 = self.at(2);
        return switch (c) {
            '=' => if (c1 != '=') .{ .op = null, .len = 1 } else null,
            '+' => if (c1 == '=') .{ .op = .add, .len = 2 } else null,
            '-' => if (c1 == '=') .{ .op = .sub, .len = 2 } else null,
            '*' => if (c1 == '=') .{ .op = .mul, .len = 2 } else null,
            '/' => if (c1 == '=') .{ .op = .div, .len = 2 } else null,
            '%' => if (c1 == '=') .{ .op = .mod, .len = 2 } else null,
            '&' => if (c1 == '=') .{ .op = .bit_and, .len = 2 } else null,
            '^' => if (c1 == '=') .{ .op = .bit_xor, .len = 2 } else null,
            '|' => if (c1 == '=') .{ .op = .bit_or, .len = 2 } else null,
            '<' => if (c1 == '<' and c2 == '=') .{ .op = .shl, .len = 3 } else null,
            '>' => if (c1 == '>' and c2 == '=') .{ .op = .shr, .len = 3 } else null,
            else => null,
        };
    }

    fn parse_assign(self: *A) AErr!*const ast.Arith {
        try self.enter();
        defer self.leave();
        const lhs = try self.parse_ternary();
        self.ws();
        if (self.assign_op()) |ao| {
            if (lhs.* != .variable) return self.fail("attempted assignment to non-variable");
            self.lx.pos += ao.len;
            const rhs = try self.parse_assign();
            return self.mk(.{ .assign = .{ .op = ao.op, .target = lhs, .value = rhs } });
        }
        return lhs;
    }

    fn parse_ternary(self: *A) AErr!*const ast.Arith {
        try self.enter();
        defer self.leave();
        const c = try self.parse_binary(1);
        self.ws();
        if (self.at(0) != '?') return c;
        self.lx.pos += 1;
        const a = try self.parse_comma();
        self.ws();
        if (self.at(0) != ':') return self.fail("expression expected");
        self.lx.pos += 1;
        const b = try self.parse_ternary();
        return self.mk(.{ .ternary = .{ .cond = c, .then = a, .otherwise = b } });
    }

    fn bin_at(self: *A) ?BinInfo {
        const c = self.at(0);
        const c1 = self.at(1);
        const c2 = self.at(2);
        return switch (c) {
            '|' => if (c1 == '|') .{ .op = .log_or, .len = 2, .prec = 1 } else if (c1 == '=') null else .{ .op = .bit_or, .len = 1, .prec = 3 },
            '&' => if (c1 == '&') .{ .op = .log_and, .len = 2, .prec = 2 } else if (c1 == '=') null else .{ .op = .bit_and, .len = 1, .prec = 5 },
            '^' => if (c1 == '=') null else .{ .op = .bit_xor, .len = 1, .prec = 4 },
            '=' => if (c1 == '=') .{ .op = .eq, .len = 2, .prec = 6 } else null,
            '!' => if (c1 == '=') .{ .op = .ne, .len = 2, .prec = 6 } else null,
            '<' => if (c1 == '=') .{ .op = .le, .len = 2, .prec = 7 } else if (c1 == '<') (if (c2 == '=') null else .{ .op = .shl, .len = 2, .prec = 8 }) else .{ .op = .lt, .len = 1, .prec = 7 },
            '>' => if (c1 == '=') .{ .op = .ge, .len = 2, .prec = 7 } else if (c1 == '>') (if (c2 == '=') null else .{ .op = .shr, .len = 2, .prec = 8 }) else .{ .op = .gt, .len = 1, .prec = 7 },
            '+' => if (c1 == '=') null else .{ .op = .add, .len = 1, .prec = 9 },
            '-' => if (c1 == '=') null else .{ .op = .sub, .len = 1, .prec = 9 },
            '*' => if (c1 == '*') (if (c2 == '=') null else .{ .op = .pow, .len = 2, .prec = 11 }) else if (c1 == '=') null else .{ .op = .mul, .len = 1, .prec = 10 },
            '/' => if (c1 == '=') null else .{ .op = .div, .len = 1, .prec = 10 },
            '%' => if (c1 == '=') null else .{ .op = .mod, .len = 1, .prec = 10 },
            else => null,
        };
    }

    fn parse_binary(self: *A, min_prec: u8) AErr!*const ast.Arith {
        try self.enter();
        defer self.leave();
        var lhs = try self.parse_unary();
        while (true) {
            self.ws();
            const info = self.bin_at() orelse break;
            if (info.prec < min_prec) break;
            self.lx.pos += info.len;
            const next_min: u8 = if (info.op == .pow) info.prec else info.prec + 1;
            const rhs = try self.parse_binary(next_min);
            lhs = try self.mk(.{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parse_unary(self: *A) AErr!*const ast.Arith {
        try self.enter();
        defer self.leave();
        self.ws();
        const c = self.at(0);
        const c1 = self.at(1);
        switch (c) {
            '!' => {
                self.lx.pos += 1;
                const e = try self.parse_unary();
                return self.mk(.{ .unary = .{ .op = .log_not, .operand = e } });
            },
            '~' => {
                self.lx.pos += 1;
                const e = try self.parse_unary();
                return self.mk(.{ .unary = .{ .op = .bit_not, .operand = e } });
            },
            '-' => {
                if (c1 == '-') {
                    self.lx.pos += 2;
                    const e = try self.parse_unary();
                    if (e.* != .variable) return self.fail("syntax error: operand expected");
                    return self.mk(.{ .incdec = .{ .kind = .pre_dec, .target = e } });
                }
                self.lx.pos += 1;
                const e = try self.parse_unary();
                return self.mk(.{ .unary = .{ .op = .neg, .operand = e } });
            },
            '+' => {
                if (c1 == '+') {
                    self.lx.pos += 2;
                    const e = try self.parse_unary();
                    if (e.* != .variable) return self.fail("syntax error: operand expected");
                    return self.mk(.{ .incdec = .{ .kind = .pre_inc, .target = e } });
                }
                self.lx.pos += 1;
                const e = try self.parse_unary();
                return self.mk(.{ .unary = .{ .op = .plus, .operand = e } });
            },
            else => return self.parse_postfix(),
        }
    }

    fn parse_postfix(self: *A) AErr!*const ast.Arith {
        const p = try self.parse_primary();
        self.ws();
        const c = self.at(0);
        if ((c == '+' or c == '-') and self.at(1) == c and p.* == .variable) {
            self.lx.pos += 2;
            return self.mk(.{ .incdec = .{ .kind = if (c == '+') .post_inc else .post_dec, .target = p } });
        }
        return p;
    }

    fn is_atom_char(c: u8) bool {
        return Lexer.is_name_char(c);
    }

    fn parse_const(text: []const u8) ?i64 {
        if (text.len == 0) return null;
        if (std.mem.findScalar(u8, text, '#')) |h| {
            const base = std.fmt.parseInt(u32, text[0..h], 10) catch return null;
            if (base < 2 or base > 64) return null;
            const digits = text[h + 1 ..];
            if (digits.len == 0) return null;
            var v: u64 = 0;
            for (digits) |d| {
                const dv: u32 = switch (d) {
                    '0'...'9' => d - '0',
                    'a'...'z' => d - 'a' + 10,
                    'A'...'Z' => if (base <= 36) d - 'A' + 10 else d - 'A' + 36,
                    '@' => 62,
                    '_' => 63,
                    else => return null,
                };
                if (dv >= base) return null;
                v = v *% base +% dv;
            }
            return @bitCast(v);
        }
        var base: u32 = 10;
        var digits = text;
        if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            base = 16;
            digits = text[2..];
        } else if (text.len > 1 and text[0] == '0') {
            base = 8;
            digits = text[1..];
        }
        var v: u64 = 0;
        for (digits) |d| {
            const dv: u32 = switch (d) {
                '0'...'9' => d - '0',
                'a'...'f' => d - 'a' + 10,
                'A'...'F' => d - 'A' + 10,
                else => return null,
            };
            if (dv >= base) return null;
            v = v *% base +% dv;
        }
        return @bitCast(v);
    }

    fn parse_primary(self: *A) AErr!*const ast.Arith {
        self.ws();
        const lx = self.lx;
        if (lx.pos >= lx.src.len) return self.fail("syntax error: operand expected");
        if (lx.src[lx.pos] == '(') {
            lx.pos += 1;
            const e = try self.parse_comma();
            self.ws();
            if (self.at(0) != ')') return self.fail("syntax error: expected `)'");
            lx.pos += 1;
            return e;
        }
        const src = lx.src;
        const start = lx.pos;
        const base = lx.parts.items.len;
        var run = start;
        var has_exp = false;
        const digit_start = src[start] >= '0' and src[start] <= '9';
        while (lx.pos < src.len) {
            const c = src[lx.pos];
            if (c == '$' and lx.dollar_starts(false)) {
                if (lx.pos > run) try lx.parts.append(lx.arena, .{ .lit = src[run..lx.pos] });
                try lx.scan_dollar(.{ .kind = .plain }, false);
                run = lx.pos;
                has_exp = true;
            } else if (c == '`') {
                if (lx.pos > run) try lx.parts.append(lx.arena, .{ .lit = src[run..lx.pos] });
                try lx.scan_backtick(false);
                run = lx.pos;
                has_exp = true;
            } else if (is_atom_char(c) or (digit_start and (c == '#' or c == '@'))) {
                lx.pos += 1;
            } else break;
        }
        if (lx.pos == start) return self.fail("syntax error: operand expected");
        if (has_exp) {
            if (lx.pos > run) try lx.parts.append(lx.arena, .{ .lit = src[run..lx.pos] });
            const parts = try lx.finish_parts(base);
            return self.mk(.{ .expansion = .{ .parts = parts, .line = lx.line_at(start) } });
        }
        const text = src[start..lx.pos];
        if (digit_start) {
            if (parse_const(text)) |v| return self.mk(.{ .num = v });
            return self.mk(.{ .bad_num = text });
        }
        var index: ?*const ast.Arith = null;
        var raw: []const u8 = "";
        if (lx.pos < src.len and src[lx.pos] == '[') {
            const close = lx.find_bracket_end(lx.pos) orelse return self.fail("syntax error: expected `]'");
            const inner = try parse_region(lx, lx.pos + 1, close);
            if (inner.* == .invalid) {
                self.msg = inner.invalid.msg;
                return error.ArithSyntax;
            }
            index = inner;
            raw = src[lx.pos + 1 .. close];
            lx.pos = close + 1;
        }
        return self.mk(.{ .variable = .{ .name = text, .index = index, .raw_index = raw } });
    }
};

pub fn parse_region(lx: *Lexer, start: usize, end: usize) lexer.Error!*const ast.Arith {
    const saved_src = lx.src;
    const saved_pos = lx.pos;
    defer {
        lx.src = saved_src;
        lx.pos = saved_pos;
    }
    const text = saved_src[start..end];
    var a = A{ .lx = lx };
    if (std.mem.trim(u8, text, " \t\n").len == 0) return a.alloc_node(.{ .num = 0 });
    lx.src = saved_src[0..end];
    lx.pos = start;
    const result = parse_top(&a) catch |e| switch (e) {
        error.ArithSyntax => return a.alloc_node(.{ .invalid = .{ .expr = text, .msg = a.msg } }),
        error.Syntax => return error.Syntax,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return result;
}

fn parse_top(a: *A) AErr!*const ast.Arith {
    const e = try a.parse_comma();
    a.ws();
    if (a.lx.pos < a.lx.src.len) return a.fail("syntax error in expression");
    return e;
}

test "arith constants" {
    try std.testing.expectEqual(@as(?i64, 255), A.parse_const("0xff"));
    try std.testing.expectEqual(@as(?i64, 8), A.parse_const("010"));
    try std.testing.expectEqual(@as(?i64, 255), A.parse_const("16#ff"));
    try std.testing.expectEqual(@as(?i64, 5), A.parse_const("2#101"));
    try std.testing.expectEqual(@as(?i64, null), A.parse_const("08"));
    try std.testing.expectEqual(@as(?i64, null), A.parse_const("1a"));
}

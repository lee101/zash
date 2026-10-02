const std = @import("std");
const ast = @import("ast.zig");
const arith_parse = @import("arith_parse.zig");
const parser_mod = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Parser = parser_mod.Parser;

pub const Error = error{ Syntax, OutOfMemory };

pub const max_depth: u32 = 400;

pub const Options = struct {
    extglob: bool = true,
};

pub const Tag = enum {
    eof,
    newline,
    word,
    assign,
    io_number,
    io_var,
    pipe,
    pipe_amp,
    and_if,
    or_if,
    semi,
    dsemi,
    semi_amp,
    dsemi_amp,
    amp,
    lparen,
    rparen,
    less,
    great,
    dless,
    dless_dash,
    tless,
    dgreat,
    less_and,
    great_and,
    less_great,
    clobber,
    and_great,
    and_dgreat,
};

pub const Kw = enum {
    none,
    kw_if,
    kw_then,
    kw_else,
    kw_elif,
    kw_fi,
    kw_for,
    kw_while,
    kw_until,
    kw_do,
    kw_done,
    kw_case,
    kw_esac,
    kw_in,
    kw_select,
    kw_function,
    kw_time,
    kw_bang,
    kw_lbrace,
    kw_rbrace,
    kw_dlbracket,
    kw_drbracket,
    kw_coproc,
};

pub const Token = struct {
    tag: Tag = .eof,
    kw: Kw = .none,
    start: u32 = 0,
    end: u32 = 0,
    parts: []const ast.Part = &.{},
    assign: ?*const ast.Assign = null,
    num: u32 = 0,
    name: []const u8 = "",
};

pub const ParseError = struct {
    kind: Kind,
    line: u32,
    col: u32,
    eof_line: u32 = 0,
    text: []const u8 = "",
    detail: []const u8 = "",
    src_line: []const u8 = "",

    pub const Kind = enum { unexpected_token, unexpected_eof, eof_matching, eof_looking, cond_syntax, arith_for, nesting };

    pub fn write(self: ParseError, w: *std.Io.Writer, prefix: []const u8) std.Io.Writer.Error!void {
        switch (self.kind) {
            .unexpected_token => {
                try w.print("{s}: line {d}: syntax error near unexpected token `{s}'\n", .{ prefix, self.line, self.text });
                try w.print("{s}: line {d}: `{s}'\n", .{ prefix, self.line, self.src_line });
            },
            .unexpected_eof => {
                try w.print("{s}: line {d}: syntax error: unexpected end of file\n", .{ prefix, self.eof_line });
            },
            .eof_matching => {
                try w.print("{s}: line {d}: unexpected EOF while looking for matching `{s}'\n", .{ prefix, self.line, self.text });
                try w.print("{s}: line {d}: syntax error: unexpected end of file\n", .{ prefix, self.eof_line });
            },
            .eof_looking => {
                try w.print("{s}: line {d}: unexpected EOF while looking for `{s}'\n", .{ prefix, self.line, self.text });
                try w.print("{s}: line {d}: syntax error: unexpected end of file\n", .{ prefix, self.eof_line });
            },
            .cond_syntax => {
                if (self.detail.len > 0) try w.print("{s}: line {d}: {s}\n", .{ prefix, self.line, self.detail });
                try w.print("{s}: line {d}: syntax error near `{s}'\n", .{ prefix, self.line, self.text });
                try w.print("{s}: line {d}: `{s}'\n", .{ prefix, self.line, self.src_line });
            },
            .arith_for => {
                try w.print("{s}: line {d}: syntax error: {s}\n", .{ prefix, self.line, self.detail });
                try w.print("{s}: line {d}: syntax error: `{s}'\n", .{ prefix, self.line, self.text });
            },
            .nesting => {
                try w.print("{s}: line {d}: syntax error: maximum nesting level exceeded\n", .{ prefix, self.line });
            },
        }
    }
};

pub const Ctx = struct {
    kind: Kind,
    dq: bool = false,
    assign: bool = false,
    brace: bool = true,

    pub const Kind = enum { word, array_elem, brace_alt, param_word, param_pat, dquote, heredoc, regex, plain };
};

const Run = struct {
    start: usize,
    buffered: bool = false,

    fn drop(self: *Run, lx: *Lexer, upto: usize, resume_at: usize) Allocator.Error!void {
        if (!self.buffered) {
            lx.buf.clearRetainingCapacity();
            self.buffered = true;
        }
        try lx.buf.appendSlice(lx.arena, lx.src[self.start..upto]);
        self.start = resume_at;
    }

    fn emit(self: *Run, lx: *Lexer, upto: usize) Allocator.Error!void {
        var text: []const u8 = undefined;
        if (self.buffered) {
            try lx.buf.appendSlice(lx.arena, lx.src[self.start..upto]);
            text = if (lx.buf.items.len == 0) "" else try lx.arena.dupe(u8, lx.buf.items);
            self.buffered = false;
        } else {
            text = lx.src[self.start..upto];
        }
        if (text.len > 0) try lx.parts.append(lx.arena, .{ .lit = text });
        self.start = upto;
    }
};

pub const Lexer = struct {
    arena: Allocator,
    src: []const u8,
    orig: []const u8,
    pos: usize = 0,
    line_base: u32 = 1,
    cache_off: usize = 0,
    cache_line: u32 = 1,
    parts: std.ArrayList(ast.Part) = .empty,
    buf: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(*ast.Heredoc) = .empty,
    err: ?ParseError = null,
    extglob: bool = true,
    depth: u32 = 0,
    no_heredoc: bool = false,
    subst_depth: u32 = 0,

    pub fn init(arena: Allocator, src: []const u8, opts: Options) Lexer {
        return .{ .arena = arena, .src = src, .orig = src, .extglob = opts.extglob };
    }

    pub fn line_at(self: *Lexer, off: usize) u32 {
        if (off < self.cache_off) {
            self.cache_off = 0;
            self.cache_line = self.line_base;
        }
        const lim = @min(off, self.orig.len);
        if (lim > self.cache_off) {
            self.cache_line += @intCast(std.mem.countScalar(u8, self.orig[self.cache_off..lim], '\n'));
            self.cache_off = lim;
        }
        return self.cache_line;
    }

    fn col_at(self: *Lexer, off: usize) u32 {
        const lim = @min(off, self.orig.len);
        const ls = if (std.mem.findScalarLast(u8, self.orig[0..lim], '\n')) |i| i + 1 else 0;
        return @intCast(lim - ls + 1);
    }

    fn line_text(self: *Lexer, off: usize) []const u8 {
        const lim = @min(off, self.orig.len);
        const ls = if (std.mem.findScalarLast(u8, self.orig[0..lim], '\n')) |i| i + 1 else 0;
        const le = if (std.mem.findScalarPos(u8, self.orig, lim, '\n')) |i| i else self.orig.len;
        return self.orig[ls..le];
    }

    fn eof_line(self: *Lexer) u32 {
        const n: u32 = @intCast(std.mem.countScalar(u8, self.orig, '\n'));
        const extra: u32 = if (self.orig.len > 0 and self.orig[self.orig.len - 1] != '\n') 2 else 1;
        return self.line_base + n + extra - 1;
    }

    pub fn fail_unexpected(self: *Lexer, tok: Token) Error {
        if (self.err != null) return error.Syntax;
        if (tok.tag == .eof) {
            self.err = .{ .kind = .unexpected_eof, .line = self.eof_line(), .col = 0, .eof_line = self.eof_line() };
            return error.Syntax;
        }
        const text = if (tok.tag == .newline) "newline" else self.orig[tok.start..tok.end];
        self.err = .{
            .kind = .unexpected_token,
            .line = self.line_at(tok.start),
            .col = self.col_at(tok.start),
            .text = text,
            .src_line = self.line_text(tok.start),
        };
        return error.Syntax;
    }

    pub fn fail_newline(self: *Lexer) Error {
        const at: u32 = @intCast(if (self.orig.len > 0 and self.orig[self.orig.len - 1] == '\n') self.orig.len - 1 else self.orig.len);
        return self.fail_unexpected(.{ .tag = .newline, .start = at, .end = at });
    }

    pub fn fail_matching(self: *Lexer, ch: []const u8, at: usize) Error {
        if (self.err != null) return error.Syntax;
        self.err = .{
            .kind = .eof_matching,
            .line = self.line_at(at),
            .col = self.col_at(at),
            .eof_line = self.eof_line(),
            .text = ch,
        };
        return error.Syntax;
    }

    pub fn fail_looking(self: *Lexer, ch: []const u8, at: usize) Error {
        if (self.err != null) return error.Syntax;
        self.err = .{
            .kind = .eof_looking,
            .line = self.line_at(at),
            .col = self.col_at(at),
            .eof_line = self.eof_line(),
            .text = ch,
        };
        return error.Syntax;
    }

    pub fn fail_cond(self: *Lexer, detail: []const u8, tok: Token) Error {
        if (self.err != null) return error.Syntax;
        const text = if (tok.tag == .newline) "newline" else if (tok.tag == .eof) "newline" else self.orig[tok.start..tok.end];
        self.err = .{
            .kind = .cond_syntax,
            .line = self.line_at(tok.start),
            .col = self.col_at(tok.start),
            .text = text,
            .detail = detail,
            .src_line = self.line_text(tok.start),
        };
        return error.Syntax;
    }

    pub fn fail_arith_for(self: *Lexer, detail: []const u8, from: usize, to: usize) Error {
        if (self.err != null) return error.Syntax;
        self.err = .{
            .kind = .arith_for,
            .line = self.line_at(from),
            .col = self.col_at(from),
            .text = self.orig[from..@min(to, self.orig.len)],
            .detail = detail,
        };
        return error.Syntax;
    }

    pub fn fail_nesting(self: *Lexer) Error {
        if (self.err != null) return error.Syntax;
        self.err = .{ .kind = .nesting, .line = self.line_at(self.pos), .col = self.col_at(self.pos) };
        return error.Syntax;
    }

    fn is_blank(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn is_meta(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '|', '&', ';', '(', ')', '<', '>' => true,
            else => false,
        };
    }

    pub fn is_name_start(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    pub fn is_name_char(c: u8) bool {
        return is_name_start(c) or (c >= '0' and c <= '9');
    }

    fn is_digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    pub fn skip_blanks(self: *Lexer) void {
        const src = self.src;
        while (self.pos < src.len) {
            const c = src[self.pos];
            if (is_blank(c)) {
                self.pos += 1;
            } else if (c == '\\' and self.pos + 1 < src.len and src[self.pos + 1] == '\n') {
                self.pos += 2;
            } else break;
        }
    }

    fn tok_at(self: *Lexer, tag: Tag, len: usize) Token {
        const s = self.pos;
        self.pos += len;
        return .{ .tag = tag, .start = @intCast(s), .end = @intCast(self.pos) };
    }

    pub fn next(self: *Lexer, allow_assign: bool) Error!Token {
        while (true) {
            self.skip_blanks();
            if (self.pos < self.src.len and self.src[self.pos] == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
        const src = self.src;
        if (self.pos >= src.len) return .{ .tag = .eof, .start = @intCast(src.len), .end = @intCast(src.len) };
        const c = src[self.pos];
        const c1: u8 = if (self.pos + 1 < src.len) src[self.pos + 1] else 0;
        const c2: u8 = if (self.pos + 2 < src.len) src[self.pos + 2] else 0;
        switch (c) {
            '\n' => {
                const t = self.tok_at(.newline, 1);
                if (self.pending.items.len > 0 and !self.no_heredoc) try self.read_heredocs();
                return t;
            },
            '|' => return switch (c1) {
                '|' => self.tok_at(.or_if, 2),
                '&' => self.tok_at(.pipe_amp, 2),
                else => self.tok_at(.pipe, 1),
            },
            '&' => return switch (c1) {
                '&' => self.tok_at(.and_if, 2),
                '>' => if (c2 == '>') self.tok_at(.and_dgreat, 3) else self.tok_at(.and_great, 2),
                else => self.tok_at(.amp, 1),
            },
            ';' => return switch (c1) {
                ';' => if (c2 == '&') self.tok_at(.dsemi_amp, 3) else self.tok_at(.dsemi, 2),
                '&' => self.tok_at(.semi_amp, 2),
                else => self.tok_at(.semi, 1),
            },
            '(' => return self.tok_at(.lparen, 1),
            ')' => return self.tok_at(.rparen, 1),
            '<' => {
                if (c1 != '(') return switch (c1) {
                    '<' => if (c2 == '<') self.tok_at(.tless, 3) else if (c2 == '-') self.tok_at(.dless_dash, 3) else self.tok_at(.dless, 2),
                    '&' => self.tok_at(.less_and, 2),
                    '>' => self.tok_at(.less_great, 2),
                    else => self.tok_at(.less, 1),
                };
            },
            '>' => {
                if (c1 != '(') return switch (c1) {
                    '>' => self.tok_at(.dgreat, 2),
                    '&' => self.tok_at(.great_and, 2),
                    '|' => self.tok_at(.clobber, 2),
                    else => self.tok_at(.great, 1),
                };
            },
            '0'...'9' => {
                var j = self.pos;
                while (j < src.len and is_digit(src[j])) j += 1;
                if (j < src.len and (src[j] == '<' or src[j] == '>') and !(j + 1 < src.len and src[j + 1] == '(')) {
                    const n = std.fmt.parseInt(u32, src[self.pos..j], 10) catch std.math.maxInt(u32);
                    const s = self.pos;
                    self.pos = j;
                    return .{ .tag = .io_number, .start = @intCast(s), .end = @intCast(j), .num = n };
                }
            },
            '{' => {
                var j = self.pos + 1;
                if (j < src.len and is_name_start(src[j])) {
                    while (j < src.len and is_name_char(src[j])) j += 1;
                    if (j + 1 < src.len and src[j] == '}' and (src[j + 1] == '<' or src[j + 1] == '>') and !(j + 2 < src.len and src[j + 2] == '(')) {
                        const s = self.pos;
                        const name = src[s + 1 .. j];
                        self.pos = j + 1;
                        return .{ .tag = .io_var, .start = @intCast(s), .end = @intCast(j + 1), .name = name };
                    }
                }
            },
            else => {},
        }
        return self.scan_word_token(allow_assign);
    }

    fn keyword_of(text: []const u8) Kw {
        return switch (text.len) {
            1 => switch (text[0]) {
                '!' => .kw_bang,
                '{' => .kw_lbrace,
                '}' => .kw_rbrace,
                else => .none,
            },
            2 => if (std.mem.eql(u8, text, "if")) .kw_if else if (std.mem.eql(u8, text, "fi")) .kw_fi else if (std.mem.eql(u8, text, "do")) .kw_do else if (std.mem.eql(u8, text, "in")) .kw_in else if (std.mem.eql(u8, text, "[[")) .kw_dlbracket else if (std.mem.eql(u8, text, "]]")) .kw_drbracket else .none,
            3 => if (std.mem.eql(u8, text, "for")) .kw_for else .none,
            4 => if (std.mem.eql(u8, text, "then")) .kw_then else if (std.mem.eql(u8, text, "else")) .kw_else else if (std.mem.eql(u8, text, "elif")) .kw_elif else if (std.mem.eql(u8, text, "done")) .kw_done else if (std.mem.eql(u8, text, "case")) .kw_case else if (std.mem.eql(u8, text, "esac")) .kw_esac else if (std.mem.eql(u8, text, "time")) .kw_time else .none,
            5 => if (std.mem.eql(u8, text, "while")) .kw_while else if (std.mem.eql(u8, text, "until")) .kw_until else .none,
            6 => if (std.mem.eql(u8, text, "select")) .kw_select else if (std.mem.eql(u8, text, "coproc")) .kw_coproc else .none,
            8 => if (std.mem.eql(u8, text, "function")) .kw_function else .none,
            else => .none,
        };
    }

    pub fn finish_parts(self: *Lexer, base: usize) Allocator.Error![]const ast.Part {
        const n = self.parts.items.len - base;
        const out = if (n == 0) &[_]ast.Part{} else try self.arena.dupe(ast.Part, self.parts.items[base..]);
        self.parts.items.len = base;
        return out;
    }

    fn scan_word_token(self: *Lexer, allow_assign: bool) Error!Token {
        const start = self.pos;
        if (allow_assign) {
            if (try self.try_assign(start)) |t| return t;
        }
        const base = self.parts.items.len;
        try self.scan_parts(.{ .kind = .word });
        if (self.pos == start) {
            self.parts.items.len = base;
            return self.fail_unexpected(.{ .tag = .word, .start = @intCast(start), .end = @intCast(@min(start + 1, self.src.len)) });
        }
        const parts = try self.finish_parts(base);
        var tok = Token{ .tag = .word, .start = @intCast(start), .end = @intCast(self.pos), .parts = parts };
        if (parts.len == 1) switch (parts[0]) {
            .lit => |t| tok.kw = keyword_of(t),
            else => {},
        };
        return tok;
    }

    pub fn next_cond(self: *Lexer, regex: bool) Error!Token {
        while (true) {
            self.skip_blanks();
            if (self.pos < self.src.len and self.src[self.pos] == '\n') {
                _ = self.tok_at(.newline, 1);
                if (self.pending.items.len > 0 and !self.no_heredoc) try self.read_heredocs();
                continue;
            }
            break;
        }
        const src = self.src;
        if (self.pos >= src.len) return .{ .tag = .eof, .start = @intCast(src.len), .end = @intCast(src.len) };
        const c = src[self.pos];
        const c1: u8 = if (self.pos + 1 < src.len) src[self.pos + 1] else 0;
        if (!regex) {
            switch (c) {
                '(' => return self.tok_at(.lparen, 1),
                ')' => return self.tok_at(.rparen, 1),
                '&' => if (c1 == '&') return self.tok_at(.and_if, 2),
                '|' => if (c1 == '|') return self.tok_at(.or_if, 2),
                '<' => if (c1 != '(') return self.tok_at(.less, 1),
                '>' => if (c1 != '(') return self.tok_at(.great, 1),
                '#' => {},
                else => {},
            }
        } else if (c == ')') {
            return self.tok_at(.rparen, 1);
        }
        const start = self.pos;
        const base = self.parts.items.len;
        try self.scan_parts(.{ .kind = if (regex) .regex else .word, .brace = false });
        if (self.pos == start) {
            self.parts.items.len = base;
            return self.fail_unexpected(.{ .tag = .word, .start = @intCast(start), .end = @intCast(@min(start + 1, self.src.len)) });
        }
        const parts = try self.finish_parts(base);
        var tok = Token{ .tag = .word, .start = @intCast(start), .end = @intCast(self.pos), .parts = parts };
        if (parts.len == 1) switch (parts[0]) {
            .lit => |t| tok.kw = keyword_of(t),
            else => {},
        };
        return tok;
    }

    pub fn find_bracket_end(self: *Lexer, open: usize) ?usize {
        const src = self.src;
        var depth: u32 = 0;
        var i = open;
        while (i < src.len) : (i += 1) {
            switch (src[i]) {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                '\\' => i += 1,
                '\'' => {
                    i = std.mem.findScalarPos(u8, src, i + 1, '\'') orelse return null;
                },
                '"' => {
                    i += 1;
                    while (i < src.len and src[i] != '"') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                },
                '\n' => return null,
                else => {},
            }
        }
        return null;
    }

    fn scan_region_word(self: *Lexer, from: usize, to: usize) Error!ast.Word {
        const saved = self.src;
        const saved_pos = self.pos;
        self.src = saved[0..to];
        self.pos = from;
        defer {
            self.src = saved;
            self.pos = saved_pos;
        }
        const base = self.parts.items.len;
        try self.scan_parts(.{ .kind = .plain });
        return .{ .parts = try self.finish_parts(base), .line = self.line_at(from) };
    }

    fn try_assign(self: *Lexer, start: usize) Error!?Token {
        const src = self.src;
        if (!is_name_start(src[start])) return null;
        var i = start + 1;
        while (i < src.len and is_name_char(src[i])) i += 1;
        const name = src[start..i];
        var index: ?ast.Word = null;
        if (i < src.len and src[i] == '[') {
            const close = self.find_bracket_end(i) orelse return null;
            const after = close + 1;
            const ok = after < src.len and (src[after] == '=' or (src[after] == '+' and after + 1 < src.len and src[after + 1] == '='));
            if (!ok) return null;
            index = try self.scan_region_word(i + 1, close);
            i = after;
        }
        var append = false;
        if (i < src.len and src[i] == '+') {
            append = true;
            i += 1;
        }
        if (i >= src.len or src[i] != '=') return null;
        i += 1;
        self.pos = i;
        const a = try self.arena.create(ast.Assign);
        a.* = .{ .name = name, .index = index, .append = append, .value = undefined };
        if (self.pos < src.len and src[self.pos] == '(') {
            self.pos += 1;
            a.value = .{ .array = try self.scan_array_elems(i) };
        } else {
            const base = self.parts.items.len;
            try self.scan_parts(.{ .kind = .word, .assign = true });
            a.value = .{ .scalar = .{ .parts = try self.finish_parts(base), .line = self.line_at(start) } };
        }
        return .{ .tag = .assign, .start = @intCast(start), .end = @intCast(self.pos), .assign = a };
    }

    fn scan_array_elems(self: *Lexer, open: usize) Error![]const ast.ArrayElem {
        var elems: std.ArrayList(ast.ArrayElem) = .empty;
        while (true) {
            while (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (is_blank(c) or c == '\n') {
                    self.pos += 1;
                } else if (c == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                    self.pos += 2;
                } else if (c == '#') {
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                } else break;
            }
            if (self.pos >= self.src.len) return self.fail_matching(")", open - 1);
            if (self.src[self.pos] == ')') {
                self.pos += 1;
                break;
            }
            var key: ?ast.Word = null;
            if (self.src[self.pos] == '[') {
                if (self.find_bracket_end(self.pos)) |close| {
                    if (close + 1 < self.src.len and self.src[close + 1] == '=') {
                        key = try self.scan_region_word(self.pos + 1, close);
                        self.pos = close + 2;
                    }
                }
            }
            const start = self.pos;
            const base = self.parts.items.len;
            try self.scan_parts(.{ .kind = .array_elem });
            if (self.pos == start and key == null) {
                self.parts.items.len = base;
                const c = self.src[self.pos];
                const tag: Tag = switch (c) {
                    '|' => .pipe,
                    '&' => .amp,
                    ';' => .semi,
                    '(' => .lparen,
                    '<' => .less,
                    '>' => .great,
                    else => .word,
                };
                return self.fail_unexpected(.{ .tag = tag, .start = @intCast(start), .end = @intCast(start + 1) });
            }
            const w = ast.Word{ .parts = try self.finish_parts(base), .line = self.line_at(start) };
            try elems.append(self.arena, .{ .key = key, .value = w });
            if (self.pos < self.src.len and !(is_blank(self.src[self.pos]) or self.src[self.pos] == '\n' or self.src[self.pos] == ')')) {
                const c = self.src[self.pos];
                const tag: Tag = switch (c) {
                    '|' => .pipe,
                    '&' => .amp,
                    ';' => .semi,
                    '(' => .lparen,
                    '<' => .less,
                    '>' => .great,
                    else => .word,
                };
                return self.fail_unexpected(.{ .tag = tag, .start = @intCast(self.pos), .end = @intCast(self.pos + 1) });
            }
        }
        return elems.toOwnedSlice(self.arena);
    }

    pub fn assign_to_word(self: *Lexer, tok: Token) Allocator.Error!ast.Word {
        const a = tok.assign.?;
        const hdr_end: usize = blk: {
            var i: usize = tok.start;
            while (i < tok.end and self.orig[i] != '=') i += 1;
            break :blk i + 1;
        };
        const hdr = self.orig[tok.start..hdr_end];
        var list: std.ArrayList(ast.Part) = .empty;
        try list.append(self.arena, .{ .lit = hdr });
        switch (a.value) {
            .scalar => |w| try list.appendSlice(self.arena, w.parts),
            .array => |elems| try list.append(self.arena, .{ .array_init = elems }),
        }
        return .{ .parts = try list.toOwnedSlice(self.arena), .line = self.line_at(tok.start) };
    }

    fn word_stop(c: u8) bool {
        return is_meta(c);
    }

    fn is_stop(ctx: Ctx, c: u8) bool {
        return switch (ctx.kind) {
            .word, .array_elem => is_meta(c),
            .brace_alt => is_meta(c) or c == ',' or c == '}',
            .param_word => c == '}',
            .param_pat => c == '}' or c == '/',
            .dquote => c == '"',
            .heredoc, .plain, .regex => false,
        };
    }

    fn brace_plausible(self: *Lexer, open: usize) bool {
        const src = self.src;
        var depth: u32 = 0;
        var saw = false;
        var i = open + 1;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            switch (c) {
                ' ', '\t', '\n', ';', '|', '&', '<', '>', ')' => return false,
                '(' => return false,
                '\\' => i += 1,
                '\'' => i = std.mem.findScalarPos(u8, src, i + 1, '\'') orelse return false,
                '"' => {
                    i += 1;
                    while (i < src.len and src[i] != '"') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                },
                '`' => i = std.mem.findScalarPos(u8, src, i + 1, '`') orelse return false,
                '$' => {
                    if (i + 1 < src.len and (src[i + 1] == '(' or src[i + 1] == '{')) {
                        const open_c = src[i + 1];
                        const close_c: u8 = if (open_c == '(') ')' else '}';
                        var d: u32 = 0;
                        var j = i + 1;
                        while (j < src.len) : (j += 1) {
                            if (src[j] == open_c) d += 1;
                            if (src[j] == close_c) {
                                d -= 1;
                                if (d == 0) break;
                            }
                        }
                        if (j >= src.len) return false;
                        i = j;
                    }
                },
                '{' => depth += 1,
                '}' => {
                    if (depth == 0) return saw;
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    saw = true;
                },
                '.' => if (depth == 0 and i + 1 < src.len and src[i + 1] == '.') {
                    saw = true;
                },
                else => {},
            }
        }
        return false;
    }

    fn valid_seq_int(t: []const u8) bool {
        if (t.len == 0) return false;
        var i: usize = 0;
        if (t[0] == '-' or t[0] == '+') i = 1;
        if (i >= t.len) return false;
        while (i < t.len) : (i += 1) if (!is_digit(t[i])) return false;
        return true;
    }

    fn is_alpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn parse_seq(text: []const u8) ?ast.BraceSeq {
        const first = std.mem.find(u8, text, "..") orelse return null;
        const from = text[0..first];
        const rest = text[first + 2 ..];
        var to = rest;
        var step: ?[]const u8 = null;
        if (std.mem.find(u8, rest, "..")) |j| {
            to = rest[0..j];
            step = rest[j + 2 ..];
            if (!valid_seq_int(step.?)) return null;
        }
        if (valid_seq_int(from) and valid_seq_int(to)) return .{ .from = from, .to = to, .step = step };
        if (from.len == 1 and to.len == 1 and is_alpha(from[0]) and is_alpha(to[0])) return .{ .from = from, .to = to, .step = step, .chars = true };
        return null;
    }

    fn try_brace(self: *Lexer) Error!bool {
        const save_pos = self.pos;
        const save_parts = self.parts.items.len;
        self.pos += 1;
        var alts: std.ArrayList(ast.Word) = .empty;
        while (true) {
            const base = self.parts.items.len;
            const ws = self.pos;
            try self.scan_parts(.{ .kind = .brace_alt });
            const w = ast.Word{ .parts = try self.finish_parts(base), .line = self.line_at(ws) };
            try alts.append(self.arena, w);
            if (self.pos < self.src.len and self.src[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.pos < self.src.len and self.src[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            self.pos = save_pos;
            self.parts.items.len = save_parts;
            return false;
        }
        if (alts.items.len == 1) {
            const text = ast.word_is_plain_lit(alts.items[0]) orelse {
                self.pos = save_pos;
                self.parts.items.len = save_parts;
                return false;
            };
            if (parse_seq(text)) |seq| {
                try self.parts.append(self.arena, .{ .brace_seq = seq });
                return true;
            }
            self.pos = save_pos;
            self.parts.items.len = save_parts;
            return false;
        }
        try self.parts.append(self.arena, .{ .brace_list = try alts.toOwnedSlice(self.arena) });
        return true;
    }

    fn tilde_len(self: *Lexer, at: usize, colon_ends: bool) ?usize {
        const src = self.src;
        var j = at + 1;
        while (j < src.len) : (j += 1) {
            const c = src[j];
            if (c == '/' or is_meta(c)) break;
            if (colon_ends and c == ':') break;
            if (!(is_name_char(c) or c == '.' or c == '-' or c == '+')) return null;
        }
        return j - at - 1;
    }

    fn skip_extglob(self: *Lexer, at: usize) Error!usize {
        const src = self.src;
        var depth: u32 = 1;
        var i = at + 1;
        while (i < src.len) : (i += 1) {
            switch (src[i]) {
                '\\' => i += 1,
                '\'' => i = std.mem.findScalarPos(u8, src, i + 1, '\'') orelse return self.fail_matching(")", at),
                '"' => {
                    i += 1;
                    while (i < src.len and src[i] != '"') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                },
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        return self.fail_matching(")", at);
    }

    fn utf8_len(c: u8) usize {
        if (c < 0x80) return 1;
        if (c >= 0xf0) return 4;
        if (c >= 0xe0) return 3;
        if (c >= 0xc0) return 2;
        return 1;
    }

    pub fn scan_parts(self: *Lexer, ctx: Ctx) Error!void {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.fail_nesting();
        const src = self.src;
        const word_start = self.pos;
        var run = Run{ .start = self.pos };
        const dqlike = ctx.dq or ctx.kind == .dquote or ctx.kind == .heredoc;
        const wordlike = !dqlike and (ctx.kind == .word or ctx.kind == .array_elem or ctx.kind == .brace_alt);
        var rx_depth: u32 = 0;
        while (self.pos < src.len) {
            const c = src[self.pos];
            const c1: u8 = if (self.pos + 1 < src.len) src[self.pos + 1] else 0;
            if (ctx.kind == .regex) {
                if (c == ' ' or c == '\t' or c == '\n') {
                    if (rx_depth == 0) break;
                } else if (c == '(') {
                    rx_depth += 1;
                } else if (c == ')') {
                    if (rx_depth == 0) break;
                    rx_depth -= 1;
                }
            } else if (is_stop(ctx, c)) {
                if (!((c == '<' or c == '>') and c1 == '(' and wordlike)) break;
            }
            switch (c) {
                '\\' => {
                    if (c1 == '\n') {
                        try run.drop(self, self.pos, self.pos + 2);
                        self.pos += 2;
                    } else if (self.pos + 1 >= src.len) {
                        self.pos += 1;
                    } else if (dqlike) {
                        const esc = switch (c1) {
                            '$', '`', '\\' => true,
                            '"' => ctx.kind != .heredoc,
                            '}' => ctx.kind == .param_word or ctx.kind == .param_pat,
                            else => false,
                        };
                        if (esc) {
                            try run.drop(self, self.pos, self.pos + 1);
                            self.pos += 2;
                        } else self.pos += 1;
                    } else if (ctx.kind == .regex) {
                        self.pos += 2;
                    } else {
                        try run.emit(self, self.pos);
                        const n = utf8_len(c1);
                        const end = @min(self.pos + 1 + n, src.len);
                        try self.parts.append(self.arena, .{ .quoted = src[self.pos + 1 .. end] });
                        self.pos = end;
                        run.start = self.pos;
                    }
                },
                '\'' => {
                    if (dqlike or ctx.kind == .dquote) {
                        self.pos += 1;
                    } else {
                        try run.emit(self, self.pos);
                        const close = std.mem.findScalarPos(u8, src, self.pos + 1, '\'') orelse return self.fail_matching("'", self.pos);
                        try self.parts.append(self.arena, .{ .quoted = src[self.pos + 1 .. close] });
                        self.pos = close + 1;
                        run.start = self.pos;
                    }
                },
                '"' => {
                    if (ctx.kind == .heredoc) {
                        self.pos += 1;
                    } else {
                        try run.emit(self, self.pos);
                        const open = self.pos;
                        const base = self.parts.items.len;
                        self.pos += 1;
                        try self.scan_parts(.{ .kind = .dquote });
                        if (self.pos >= src.len) return self.fail_matching("\"", open);
                        self.pos += 1;
                        const inner = try self.finish_parts(base);
                        try self.parts.append(self.arena, .{ .dquote = inner });
                        run.start = self.pos;
                    }
                },
                '$' => {
                    if (self.dollar_starts(dqlike)) {
                        try run.emit(self, self.pos);
                        try self.scan_dollar(ctx, dqlike);
                        run.start = self.pos;
                    } else self.pos += 1;
                },
                '`' => {
                    try run.emit(self, self.pos);
                    try self.scan_backtick(dqlike);
                    run.start = self.pos;
                },
                '<', '>' => {
                    if (c1 == '(' and wordlike) {
                        try run.emit(self, self.pos);
                        const open = self.pos;
                        self.pos += 2;
                        const body = (try self.parse_subst_lenient(open)) orelse {
                            run.start = self.pos;
                            continue;
                        };
                        const ps = try self.arena.create(ast.ProcSubst);
                        ps.* = .{ .input = c == '<', .body = body };
                        try self.parts.append(self.arena, .{ .proc_subst = ps });
                        run.start = self.pos;
                    } else self.pos += 1;
                },
                '{' => {
                    if (ctx.brace and !ctx.assign and wordlike and self.brace_plausible(self.pos)) {
                        try run.emit(self, self.pos);
                        if (try self.try_brace()) {
                            run.start = self.pos;
                        } else {
                            run.start = self.pos;
                            self.pos += 1;
                        }
                    } else self.pos += 1;
                },
                '~' => {
                    const at_start = self.pos == word_start;
                    const after_colon = ctx.assign and self.pos > 0 and src[self.pos - 1] == ':';
                    if (!dqlike and (ctx.kind == .word or ctx.kind == .array_elem) and (at_start or after_colon)) {
                        if (self.tilde_len(self.pos, ctx.assign)) |n| {
                            try run.emit(self, self.pos);
                            try self.parts.append(self.arena, .{ .tilde = src[self.pos + 1 .. self.pos + 1 + n] });
                            self.pos += 1 + n;
                            run.start = self.pos;
                            continue;
                        }
                    }
                    self.pos += 1;
                },
                '?', '*', '+', '@', '!' => {
                    if (c1 == '(' and self.extglob and !dqlike and ctx.kind != .dquote) {
                        self.pos = try self.skip_extglob(self.pos + 1);
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        try run.emit(self, self.pos);
    }

    pub fn dollar_starts(self: *Lexer, dq: bool) bool {
        const src = self.src;
        if (self.pos + 1 >= src.len) return false;
        const n = src[self.pos + 1];
        return switch (n) {
            '(', '{', '[' => true,
            '\'', '"' => !dq,
            '@', '*', '#', '?', '-', '$', '!' => true,
            else => is_name_start(n) or is_digit(n),
        };
    }

    pub fn find_arith_end(self: *Lexer, from: usize) ?usize {
        const src = self.src;
        var depth: u32 = 0;
        var i = from;
        while (i < src.len) : (i += 1) {
            switch (src[i]) {
                '(' => depth += 1,
                ')' => {
                    if (depth == 0) {
                        if (i + 1 < src.len and src[i + 1] == ')') return i;
                        return null;
                    }
                    depth -= 1;
                },
                '\\' => i += 1,
                '\'' => i = std.mem.findScalarPos(u8, src, i + 1, '\'') orelse return null,
                '"' => {
                    i += 1;
                    while (i < src.len and src[i] != '"') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                },
                '`' => i = std.mem.findScalarPos(u8, src, i + 1, '`') orelse return null,
                else => {},
            }
        }
        return null;
    }

    pub fn extent(self: *Lexer, from: usize, stop_a: u8, stop_b: u8) ?usize {
        const src = self.src;
        var depth: u32 = 0;
        var qmarks: u32 = 0;
        var i = from;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (depth == 0) {
                if (c == '?' and stop_a == ':') qmarks += 1;
                if (c == stop_a or c == stop_b) {
                    if (c == ':' and qmarks > 0) {
                        qmarks -= 1;
                    } else return i;
                }
            }
            switch (c) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => {
                    if (depth > 0) depth -= 1;
                },
                '\\' => i += 1,
                '\'' => i = std.mem.findScalarPos(u8, src, i + 1, '\'') orelse return null,
                '"' => {
                    i += 1;
                    while (i < src.len and src[i] != '"') : (i += 1) {
                        if (src[i] == '\\') i += 1;
                    }
                },
                '`' => i = std.mem.findScalarPos(u8, src, i + 1, '`') orelse return null,
                else => {},
            }
        }
        return null;
    }

    fn parse_subst_lenient(self: *Lexer, open: usize) Error!?ast.List {
        const p: *Parser = @fieldParentPtr("lex", self);
        const parts_len = self.parts.items.len;
        return p.parse_subst_body(open) catch |e| {
            if (e != error.Syntax) return e;
            switch (self.err.?.kind) {
                .eof_matching, .unexpected_eof, .eof_looking, .nesting => return e,
                else => {},
            }
            const end = self.extent(open + 2, ')', ')') orelse return e;
            self.err = null;
            self.parts.items.len = parts_len;
            self.pos = end + 1;
            try self.parts.append(self.arena, .{ .bad_subst = self.src[open .. end + 1] });
            return null;
        };
    }

    pub fn scan_dollar(self: *Lexer, ctx: Ctx, dq: bool) Error!void {
        const src = self.src;
        const open = self.pos;
        const n = src[open + 1];
        switch (n) {
            '(' => {
                if (open + 2 < src.len and src[open + 2] == '(') {
                    if (self.find_arith_end(open + 3)) |end| {
                        const e = try arith_parse.parse_region(self, open + 3, end);
                        self.pos = end + 2;
                        try self.parts.append(self.arena, .{ .arith = e });
                        return;
                    }
                }
                self.pos = open + 2;
                const body = (try self.parse_subst_lenient(open)) orelse return;
                const cs = try self.arena.create(ast.CmdSubst);
                cs.* = .{ .body = body };
                try self.parts.append(self.arena, .{ .cmd_subst = cs });
            },
            '[' => {
                const close = self.find_bracket_end(open + 1) orelse return self.fail_matching("]", open);
                const e = try arith_parse.parse_region(self, open + 2, close);
                self.pos = close + 1;
                try self.parts.append(self.arena, .{ .arith = e });
            },
            '{' => try self.scan_param(ctx, dq),
            '\'' => {
                var i = open + 2;
                self.buf.clearRetainingCapacity();
                while (true) {
                    if (i >= src.len) return self.fail_matching("'", open);
                    const c = src[i];
                    if (c == '\'') break;
                    if (c == '\\' and i + 1 < src.len) {
                        i = try self.ansi_escape(i);
                    } else {
                        try self.buf.append(self.arena, c);
                        i += 1;
                    }
                }
                self.pos = i + 1;
                try self.parts.append(self.arena, .{ .ansi_c = try self.arena.dupe(u8, self.buf.items) });
            },
            '"' => {
                const base = self.parts.items.len;
                self.pos = open + 2;
                try self.scan_parts(.{ .kind = .dquote });
                if (self.pos >= src.len) return self.fail_matching("\"", open);
                self.pos += 1;
                const inner = try self.finish_parts(base);
                try self.parts.append(self.arena, .{ .dquote = inner });
            },
            '@', '*', '#', '?', '-', '$', '!' => {
                self.pos = open + 2;
                try self.parts.append(self.arena, .{ .variable = src[open + 1 .. open + 2] });
            },
            '0'...'9' => {
                self.pos = open + 2;
                try self.parts.append(self.arena, .{ .variable = src[open + 1 .. open + 2] });
            },
            else => {
                var i = open + 1;
                while (i < src.len and is_name_char(src[i])) i += 1;
                self.pos = i;
                try self.parts.append(self.arena, .{ .variable = src[open + 1 .. i] });
            },
        }
    }

    fn hex_val(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn append_codepoint(self: *Lexer, cp: u32) Allocator.Error!void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(@min(cp, 0x10ffff)), &tmp) catch {
            try self.buf.append(self.arena, '?');
            return;
        };
        try self.buf.appendSlice(self.arena, tmp[0..n]);
    }

    fn ansi_escape(self: *Lexer, at: usize) Allocator.Error!usize {
        const src = self.src;
        const c = src[at + 1];
        var i = at + 2;
        switch (c) {
            'a' => try self.buf.append(self.arena, 7),
            'b' => try self.buf.append(self.arena, 8),
            'e', 'E' => try self.buf.append(self.arena, 27),
            'f' => try self.buf.append(self.arena, 12),
            'n' => try self.buf.append(self.arena, '\n'),
            'r' => try self.buf.append(self.arena, '\r'),
            't' => try self.buf.append(self.arena, '\t'),
            'v' => try self.buf.append(self.arena, 11),
            '\\' => try self.buf.append(self.arena, '\\'),
            '\'' => try self.buf.append(self.arena, '\''),
            '"' => try self.buf.append(self.arena, '"'),
            '?' => try self.buf.append(self.arena, '?'),
            'x' => {
                var v: u32 = 0;
                var n: u32 = 0;
                while (n < 2 and i < src.len) : (n += 1) {
                    const h = hex_val(src[i]) orelse break;
                    v = v * 16 + h;
                    i += 1;
                }
                if (n == 0) {
                    try self.buf.appendSlice(self.arena, "\\x");
                } else try self.buf.append(self.arena, @intCast(v));
            },
            'u', 'U' => {
                const max: u32 = if (c == 'u') 4 else 8;
                var v: u32 = 0;
                var n: u32 = 0;
                while (n < max and i < src.len) : (n += 1) {
                    const h = hex_val(src[i]) orelse break;
                    v = v *% 16 +% h;
                    i += 1;
                }
                if (n == 0) {
                    try self.buf.append(self.arena, '\\');
                    try self.buf.append(self.arena, c);
                } else try self.append_codepoint(v);
            },
            'c' => {
                if (i < src.len) {
                    try self.buf.append(self.arena, src[i] & 0x1f);
                    i += 1;
                }
            },
            '0'...'7' => {
                var v: u32 = c - '0';
                var n: u32 = 1;
                while (n < 3 and i < src.len and src[i] >= '0' and src[i] <= '7') : (n += 1) {
                    v = v * 8 + (src[i] - '0');
                    i += 1;
                }
                try self.buf.append(self.arena, @truncate(v));
            },
            else => {
                try self.buf.append(self.arena, '\\');
                try self.buf.append(self.arena, c);
            },
        }
        return i;
    }

    pub fn scan_backtick(self: *Lexer, dq: bool) Error!void {
        const src = self.src;
        const open = self.pos;
        var out: std.ArrayList(u8) = .empty;
        var i = open + 1;
        while (true) {
            if (i >= src.len) return self.fail_matching("`", open);
            const c = src[i];
            if (c == '`') break;
            if (c == '\\' and i + 1 < src.len) {
                const n = src[i + 1];
                if (n == '$' or n == '`' or n == '\\' or (dq and n == '"')) {
                    try out.append(self.arena, n);
                    i += 2;
                    continue;
                }
                if (n == '\n') {
                    i += 2;
                    continue;
                }
            }
            try out.append(self.arena, c);
            i += 1;
        }
        self.pos = i + 1;
        const text = try out.toOwnedSlice(self.arena);
        var sub = Parser.init(self.arena, text, .{ .extglob = self.extglob });
        sub.lex.line_base = self.line_at(open);
        sub.lex.cache_line = sub.lex.line_base;
        sub.lex.depth = self.depth;
        const body = sub.parse_script() catch |e| {
            if (e != error.Syntax) return e;
            try self.parts.append(self.arena, .{ .bad_subst = src[open..self.pos] });
            return;
        };
        const cs = try self.arena.create(ast.CmdSubst);
        cs.* = .{ .body = body, .backtick = true };
        try self.parts.append(self.arena, .{ .cmd_subst = cs });
    }

    fn operand_word(self: *Lexer, kind: Ctx.Kind, dq: bool, open: usize) Error!ast.Word {
        const base = self.parts.items.len;
        const ws = self.pos;
        try self.scan_parts(.{ .kind = kind, .dq = dq });
        if (self.pos >= self.src.len) return self.fail_matching("}", open);
        return .{ .parts = try self.finish_parts(base), .line = self.line_at(ws) };
    }

    fn bad_subst(self: *Lexer, open: usize) Error!void {
        const end = self.extent(open + 2, '}', '}') orelse return self.fail_matching("}", open);
        self.pos = end + 1;
        try self.parts.append(self.arena, .{ .bad_subst = self.src[open .. end + 1] });
    }

    fn scan_param(self: *Lexer, ctx: Ctx, dq: bool) Error!void {
        const src = self.src;
        const open = self.pos;
        var i = open + 2;
        if (i >= src.len) return self.fail_matching("}", open);
        const dqctx = dq or ctx.dq;
        var length = false;
        var indirect = false;
        const c0 = src[i];
        const c1: u8 = if (i + 1 < src.len) src[i + 1] else 0;
        const c2: u8 = if (i + 2 < src.len) src[i + 2] else 0;
        if (c0 == '#' and c1 != '}') {
            if (is_name_start(c1) or is_digit(c1)) {
                length = true;
                i += 1;
            } else if ((c1 == '@' or c1 == '*' or c1 == '?' or c1 == '$' or c1 == '!' or c1 == '-') and c2 == '}') {
                length = true;
                i += 1;
            }
        } else if (c0 == '!' and c1 != '}') {
            if (is_name_start(c1) or is_digit(c1)) {
                indirect = true;
                i += 1;
            }
        }
        if (i >= src.len) return self.fail_matching("}", open);
        const nc = src[i];
        const name_start = i;
        if (is_name_start(nc)) {
            while (i < src.len and is_name_char(src[i])) i += 1;
        } else if (is_digit(nc)) {
            while (i < src.len and is_digit(src[i])) i += 1;
        } else if (nc == '@' or nc == '*' or nc == '#' or nc == '?' or nc == '-' or nc == '$' or nc == '!') {
            i += 1;
        } else return self.bad_subst(open);
        const name = src[name_start..i];
        const pe = try self.arena.create(ast.ParamExp);
        pe.* = .{ .name = name, .indirect = indirect, .length = length };
        if (i < src.len and src[i] == '[') {
            const close = self.find_bracket_end(i) orelse return self.fail_matching("]", i);
            const inner = src[i + 1 .. close];
            if (std.mem.eql(u8, inner, "@")) {
                pe.subscript = .at;
            } else if (std.mem.eql(u8, inner, "*")) {
                pe.subscript = .star;
            } else {
                pe.subscript = .{ .index = try self.scan_region_word(i + 1, close) };
            }
            i = close + 1;
        }
        if (i >= src.len) return self.fail_matching("}", open);
        if (indirect and pe.subscript == null and (src[i] == '*' or src[i] == '@') and i + 1 < src.len and src[i + 1] == '}') {
            pe.op = .{ .prefix_names = if (src[i] == '*') .star else .at };
            i += 1;
        }
        if (src[i] == '}') {
            self.pos = i + 1;
            return self.push_param(pe);
        }
        if (length) return self.bad_subst(open);
        const oc = src[i];
        const o1: u8 = if (i + 1 < src.len) src[i + 1] else 0;
        switch (oc) {
            ':' => {
                if (o1 == '-' or o1 == '=' or o1 == '?' or o1 == '+') {
                    self.pos = i + 2;
                    const w = try self.operand_word(.param_word, dqctx, open);
                    const cw = ast.CondWord{ .colon = true, .word = w };
                    pe.op = switch (o1) {
                        '-' => .{ .use_default = cw },
                        '=' => .{ .assign_default = cw },
                        '?' => .{ .error_unset = cw },
                        else => .{ .use_alt = cw },
                    };
                } else {
                    const off_end = self.extent(i + 1, ':', '}') orelse return self.fail_matching("}", open);
                    const offset = try arith_parse.parse_region(self, i + 1, off_end);
                    var len_expr: ?*const ast.Arith = null;
                    var end = off_end;
                    if (src[off_end] == ':') {
                        const le = self.extent(off_end + 1, '}', '}') orelse return self.fail_matching("}", open);
                        len_expr = try arith_parse.parse_region(self, off_end + 1, le);
                        end = le;
                    }
                    pe.op = .{ .substring = .{ .offset = offset, .length = len_expr } };
                    self.pos = end;
                }
            },
            '-', '=', '?', '+' => {
                self.pos = i + 1;
                const w = try self.operand_word(.param_word, dqctx, open);
                const cw = ast.CondWord{ .colon = false, .word = w };
                pe.op = switch (oc) {
                    '-' => .{ .use_default = cw },
                    '=' => .{ .assign_default = cw },
                    '?' => .{ .error_unset = cw },
                    else => .{ .use_alt = cw },
                };
            },
            '#', '%' => {
                const longest = o1 == oc;
                self.pos = i + (if (longest) @as(usize, 2) else 1);
                const w = try self.operand_word(.param_word, dqctx, open);
                const kind: ast.TrimKind = if (oc == '#')
                    (if (longest) .prefix_longest else .prefix)
                else
                    (if (longest) .suffix_longest else .suffix);
                pe.op = .{ .trim = .{ .kind = kind, .pattern = w } };
            },
            '/' => {
                var kind: ast.ReplaceKind = .first;
                var j = i + 1;
                if (o1 == '/') {
                    kind = .all;
                    j += 1;
                } else if (o1 == '#') {
                    kind = .prefix;
                    j += 1;
                } else if (o1 == '%') {
                    kind = .suffix;
                    j += 1;
                }
                self.pos = j;
                const base = self.parts.items.len;
                const ws = self.pos;
                try self.scan_parts(.{ .kind = .param_pat, .dq = dqctx });
                if (self.pos >= src.len) return self.fail_matching("}", open);
                const pat = ast.Word{ .parts = try self.finish_parts(base), .line = self.line_at(ws) };
                var rep: ?ast.Word = null;
                if (src[self.pos] == '/') {
                    self.pos += 1;
                    rep = try self.operand_word(.param_word, dqctx, open);
                }
                pe.op = .{ .replace = .{ .kind = kind, .pattern = pat, .replacement = rep } };
            },
            '^', ',' => {
                const all = o1 == oc;
                self.pos = i + (if (all) @as(usize, 2) else 1);
                const w = try self.operand_word(.param_word, dqctx, open);
                pe.op = .{ .case_mod = .{ .upper = oc == '^', .all = all, .pattern = if (w.parts.len == 0) null else w } };
            },
            '@' => {
                if (i + 2 < src.len and src[i + 2] == '}' and std.mem.findScalar(u8, "QEPAaKkLUuXx", o1) != null) {
                    pe.op = .{ .transform = o1 };
                    self.pos = i + 2;
                } else return self.bad_subst(open);
            },
            else => return self.bad_subst(open),
        }
        if (self.pos >= src.len or src[self.pos] != '}') return self.fail_matching("}", open);
        self.pos += 1;
        return self.push_param(pe);
    }

    fn push_param(self: *Lexer, pe: *ast.ParamExp) Error!void {
        const simple = pe.subscript == null and !pe.indirect and !pe.length and pe.op == .none;
        if (simple) {
            try self.parts.append(self.arena, .{ .variable = pe.name });
        } else {
            try self.parts.append(self.arena, .{ .param = pe });
        }
    }

    fn read_heredocs(self: *Lexer) Error!void {
        const src = self.src;
        var list = self.pending;
        self.pending = .empty;
        for (list.items) |h| {
            const body_start = self.pos;
            var body_end = body_start;
            while (self.pos < src.len) {
                const ls = self.pos;
                const le = std.mem.findScalarPos(u8, src, ls, '\n') orelse src.len;
                const raw = src[ls..le];
                var line = raw;
                if (h.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
                self.pos = @min(le + 1, src.len);
                if (std.mem.eql(u8, line, h.delimiter)) break;
                if (self.subst_depth > 0 and line.len > h.delimiter.len and line[h.delimiter.len] == ')' and std.mem.startsWith(u8, line, h.delimiter)) {
                    self.pos = ls + (raw.len - line.len) + h.delimiter.len;
                    break;
                }
                body_end = self.pos;
            }
            var text: []const u8 = src[body_start..body_end];
            if (h.strip_tabs and text.len > 0) {
                var out: std.ArrayList(u8) = .empty;
                var it = std.mem.splitScalar(u8, text, '\n');
                var first = true;
                while (it.next()) |ln| {
                    if (!first) try out.append(self.arena, '\n');
                    first = false;
                    try out.appendSlice(self.arena, std.mem.trimStart(u8, ln, "\t"));
                }
                text = try out.toOwnedSlice(self.arena);
            }
            const line_no = self.line_at(body_start);
            if (h.quoted) {
                h.body = .{ .parts = if (text.len == 0) &.{} else try self.arena.dupe(ast.Part, &[_]ast.Part{.{ .quoted = text }}), .line = line_no };
            } else {
                var sub = Parser.init(self.arena, text, .{ .extglob = self.extglob });
                sub.lex.line_base = line_no;
                sub.lex.cache_line = line_no;
                sub.lex.depth = self.depth;
                sub.lex.scan_parts(.{ .kind = .heredoc }) catch |e| {
                    if (e == error.Syntax and self.err == null) self.err = sub.lex.err;
                    return e;
                };
                h.body = .{ .parts = try sub.lex.finish_parts(0), .line = line_no };
            }
        }
        list.clearRetainingCapacity();
    }
};

test "lexer tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "echo a|b && c;", .{});
    const lx = &p.lex;
    const want = [_]Tag{ .word, .word, .pipe, .word, .and_if, .word, .semi, .eof };
    for (want) |w| {
        const t = try lx.next(true);
        try std.testing.expectEqual(w, t.tag);
    }
}

test "lexer io number and operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "2>&1 &>>f <<-X <<<y ;;& ;& |&", .{});
    const want = [_]Tag{ .io_number, .great_and, .word, .and_dgreat, .word, .dless_dash, .word, .tless, .word, .dsemi_amp, .semi_amp, .pipe_amp, .eof };
    for (want) |w| {
        const t = try p.lex.next(true);
        try std.testing.expectEqual(w, t.tag);
    }
}

test "lexer keyword flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "if 'then' then", .{});
    try std.testing.expectEqual(Kw.kw_if, (try p.lex.next(true)).kw);
    try std.testing.expectEqual(Kw.none, (try p.lex.next(true)).kw);
    try std.testing.expectEqual(Kw.kw_then, (try p.lex.next(true)).kw);
}

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const arith_parse = @import("arith_parse.zig");

const Allocator = std.mem.Allocator;
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const Tag = lexer.Tag;
const Kw = lexer.Kw;

pub const Error = lexer.Error;
pub const ParseError = lexer.ParseError;
pub const Options = lexer.Options;

pub const Result = union(enum) {
    ok: ast.List,
    err: ParseError,
};

pub fn parse(arena: Allocator, src: []const u8, opts: Options) Result {
    var p = Parser.init(arena, src, opts);
    const list = p.parse_script() catch |e| switch (e) {
        error.Syntax => return .{ .err = p.lex.err.? },
        error.OutOfMemory => return .{ .err = .{ .kind = .nesting, .line = 0, .col = 0 } },
    };
    return .{ .ok = list };
}

pub fn parse_arith_text(arena: Allocator, text: []const u8) Error!*const ast.Arith {
    var p = Parser.init(arena, text, .{});
    return arith_parse.parse_region(&p.lex, 0, text.len);
}

pub const Parser = struct {
    lex: Lexer,
    tok: Token = .{},
    items: std.ArrayList(ast.Item) = .empty,
    words: std.ArrayList(ast.Word) = .empty,
    redirs: std.ArrayList(ast.Redirect) = .empty,
    assigns: std.ArrayList(ast.Assign) = .empty,
    cmds: std.ArrayList(ast.Command) = .empty,
    links: std.ArrayList(ast.AndOrLink) = .empty,
    clauses: std.ArrayList(ast.IfClause) = .empty,
    case_clauses: std.ArrayList(ast.CaseClause) = .empty,
    pipes: std.ArrayList(bool) = .empty,

    pub fn init(arena: Allocator, src: []const u8, opts: Options) Parser {
        return .{ .lex = Lexer.init(arena, src, opts) };
    }

    fn alloc(self: *Parser) Allocator {
        return self.lex.arena;
    }

    pub fn parse_script(self: *Parser) Error!ast.List {
        try self.advance(true);
        const list = try self.parse_list(false);
        if (self.tok.tag != .eof) return self.unexpected();
        return list;
    }

    const Lens = struct { items: usize, words: usize, redirs: usize, assigns: usize, cmds: usize, links: usize, clauses: usize, case_clauses: usize, pipes: usize };

    fn save_lens(self: *Parser) Lens {
        return .{
            .items = self.items.items.len,
            .words = self.words.items.len,
            .redirs = self.redirs.items.len,
            .assigns = self.assigns.items.len,
            .cmds = self.cmds.items.len,
            .links = self.links.items.len,
            .clauses = self.clauses.items.len,
            .case_clauses = self.case_clauses.items.len,
            .pipes = self.pipes.items.len,
        };
    }

    fn restore_lens(self: *Parser, l: Lens) void {
        self.items.items.len = l.items;
        self.words.items.len = l.words;
        self.redirs.items.len = l.redirs;
        self.assigns.items.len = l.assigns;
        self.cmds.items.len = l.cmds;
        self.links.items.len = l.links;
        self.clauses.items.len = l.clauses;
        self.case_clauses.items.len = l.case_clauses;
        self.pipes.items.len = l.pipes;
    }

    pub fn parse_subst_body(self: *Parser, open: usize) Error!ast.List {
        const lens = self.save_lens();
        errdefer self.restore_lens(lens);
        const saved_pending = self.lex.pending;
        const saved_tok = self.tok;
        self.lex.pending = .empty;
        self.lex.subst_depth += 1;
        defer {
            self.lex.pending = saved_pending;
            self.tok = saved_tok;
            self.lex.subst_depth -= 1;
        }
        try self.advance(true);
        const list = self.parse_list(false) catch |e| return self.matching_on_eof(e, open);
        if (self.tok.tag != .rparen) {
            if (self.tok.tag == .eof) return self.lex.fail_matching(")", open);
            return self.unexpected();
        }
        return list;
    }

    fn matching_on_eof(self: *Parser, e: Error, open: usize) Error {
        if (e == error.Syntax) {
            if (self.lex.err) |le| {
                if (le.kind == .unexpected_eof) {
                    self.lex.err = null;
                    return self.lex.fail_matching(")", open);
                }
            }
        }
        return e;
    }

    fn advance(self: *Parser, assign_ok: bool) Error!void {
        self.tok = try self.lex.next(assign_ok);
    }

    fn cond_advance(self: *Parser, regex: bool) Error!void {
        self.tok = try self.lex.next_cond(regex);
    }

    fn unexpected(self: *Parser) Error {
        return self.lex.fail_unexpected(self.tok);
    }

    fn is_kw(self: *Parser, kw: Kw) bool {
        return self.tok.tag == .word and self.tok.kw == kw;
    }

    fn expect_kw(self: *Parser, kw: Kw) Error!void {
        if (!self.is_kw(kw)) return self.unexpected();
        try self.advance(true);
    }

    fn skip_newlines(self: *Parser) Error!void {
        while (self.tok.tag == .newline) try self.advance(true);
    }

    fn list_end(self: *Parser) bool {
        return switch (self.tok.tag) {
            .eof, .rparen, .dsemi, .semi_amp, .dsemi_amp => true,
            .word => switch (self.tok.kw) {
                .kw_then, .kw_else, .kw_elif, .kw_fi, .kw_do, .kw_done, .kw_esac, .kw_rbrace => true,
                else => false,
            },
            else => false,
        };
    }

    fn is_redir_start(tag: Tag) bool {
        return switch (tag) {
            .io_number, .io_var, .less, .great, .dless, .dless_dash, .tless, .dgreat, .less_and, .great_and, .less_great, .clobber, .and_great, .and_dgreat => true,
            else => false,
        };
    }

    fn cur_word(self: *Parser) ast.Word {
        return .{ .parts = self.tok.parts, .line = self.lex.line_at(self.tok.start) };
    }

    fn parse_list(self: *Parser, require: bool) Error!ast.List {
        const base = self.items.items.len;
        while (true) {
            try self.skip_newlines();
            if (self.list_end()) break;
            const line = self.lex.line_at(self.tok.start);
            const ao = try self.parse_and_or();
            var bg = false;
            var sep = true;
            switch (self.tok.tag) {
                .semi => try self.advance(true),
                .amp => {
                    bg = true;
                    try self.advance(true);
                },
                .newline => try self.advance(true),
                else => sep = false,
            }
            try self.items.append(self.alloc(), .{ .and_or = ao, .background = bg, .line = line });
            if (!sep and !self.list_end()) return self.unexpected();
        }
        const n = self.items.items.len - base;
        if (n == 0 and require) return self.unexpected();
        const out: []const ast.Item = if (n == 0) &.{} else try self.alloc().dupe(ast.Item, self.items.items[base..]);
        self.items.items.len = base;
        return .{ .items = out };
    }

    fn parse_and_or(self: *Parser) Error!ast.AndOr {
        const first = try self.parse_pipeline();
        if (self.tok.tag != .and_if and self.tok.tag != .or_if) return .{ .first = first };
        const base = self.links.items.len;
        while (self.tok.tag == .and_if or self.tok.tag == .or_if) {
            const op: ast.LinkOp = if (self.tok.tag == .and_if) .and_if else .or_if;
            try self.advance(true);
            try self.skip_newlines();
            const p = try self.parse_pipeline();
            try self.links.append(self.alloc(), .{ .op = op, .pipeline = p });
        }
        const rest = try self.alloc().dupe(ast.AndOrLink, self.links.items[base..]);
        self.links.items.len = base;
        return .{ .first = first, .rest = rest };
    }

    fn at_cmd_end(self: *Parser) bool {
        return switch (self.tok.tag) {
            .newline, .eof, .semi, .amp, .rparen, .and_if, .or_if, .dsemi, .semi_amp, .dsemi_amp => true,
            else => false,
        };
    }

    fn parse_pipeline(self: *Parser) Error!ast.Pipeline {
        var negate = false;
        var time: ast.TimeMode = .none;
        while (true) {
            if (self.is_kw(.kw_bang)) {
                negate = !negate;
                try self.advance(true);
            } else if (self.is_kw(.kw_time)) {
                time = .time;
                try self.advance(true);
                while (self.tok.tag == .word) {
                    const t = ast.word_is_plain_lit(self.cur_word()) orelse break;
                    if (std.mem.eql(u8, t, "-p")) {
                        time = .time_posix;
                    } else if (!std.mem.eql(u8, t, "--")) break;
                    try self.advance(true);
                }
            } else break;
        }
        if ((time != .none or negate) and self.at_cmd_end()) return .{ .commands = &.{}, .negate = negate, .time = time };
        const base = self.cmds.items.len;
        const pbase = self.pipes.items.len;
        const c1 = try self.parse_command();
        try self.cmds.append(self.alloc(), c1);
        var any_err = false;
        while (self.tok.tag == .pipe or self.tok.tag == .pipe_amp) {
            const err_pipe = self.tok.tag == .pipe_amp;
            any_err = any_err or err_pipe;
            try self.pipes.append(self.alloc(), err_pipe);
            try self.advance(true);
            try self.skip_newlines();
            const c = try self.parse_command();
            try self.cmds.append(self.alloc(), c);
        }
        const cmds = try self.alloc().dupe(ast.Command, self.cmds.items[base..]);
        const pipes: []const bool = if (any_err) try self.alloc().dupe(bool, self.pipes.items[pbase..]) else &.{};
        self.cmds.items.len = base;
        self.pipes.items.len = pbase;
        return .{ .commands = cmds, .negate = negate, .time = time, .pipe_stderr = pipes };
    }

    fn parse_command(self: *Parser) Error!ast.Command {
        self.lex.depth += 1;
        defer self.lex.depth -= 1;
        if (self.lex.depth > lexer.max_depth) return self.lex.fail_nesting();
        const line = self.lex.line_at(self.tok.start);
        var cmd: ast.Command = undefined;
        switch (self.tok.tag) {
            .word => switch (self.tok.kw) {
                .kw_if => cmd = try self.parse_if(),
                .kw_while, .kw_until => cmd = try self.parse_while(),
                .kw_for => cmd = try self.parse_for(false),
                .kw_select => cmd = try self.parse_for(true),
                .kw_case => cmd = try self.parse_case(),
                .kw_function => cmd = try self.parse_function_kw(),
                .kw_lbrace => cmd = try self.parse_group(),
                .kw_dlbracket => cmd = try self.parse_cond_command(),
                .kw_coproc => cmd = try self.parse_coproc(),
                .kw_then, .kw_else, .kw_elif, .kw_fi, .kw_do, .kw_done, .kw_esac, .kw_rbrace, .kw_bang, .kw_time => return self.unexpected(),
                else => return self.parse_simple(line),
            },
            .lparen => cmd = try self.parse_subshell(),
            else => return self.parse_simple(line),
        }
        cmd.line = line;
        cmd.redirs = try self.parse_trailing_redirs();
        return cmd;
    }

    fn parse_trailing_redirs(self: *Parser) Error![]const ast.Redirect {
        if (!is_redir_start(self.tok.tag)) return &.{};
        const base = self.redirs.items.len;
        while (is_redir_start(self.tok.tag)) {
            const r = try self.parse_redirect(true);
            try self.redirs.append(self.alloc(), r);
        }
        const out = try self.alloc().dupe(ast.Redirect, self.redirs.items[base..]);
        self.redirs.items.len = base;
        return out;
    }

    fn heredoc_delim(self: *Parser, text: []const u8) Error!struct { []const u8, bool } {
        var out: std.ArrayList(u8) = .empty;
        var quoted = false;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            switch (c) {
                '\\' => {
                    quoted = true;
                    if (i + 1 < text.len) {
                        try out.append(self.alloc(), text[i + 1]);
                        i += 2;
                    } else i += 1;
                },
                '\'' => {
                    quoted = true;
                    const close = std.mem.findScalarPos(u8, text, i + 1, '\'') orelse text.len;
                    try out.appendSlice(self.alloc(), text[i + 1 .. close]);
                    i = close + 1;
                },
                '"' => {
                    quoted = true;
                    var j = i + 1;
                    while (j < text.len and text[j] != '"') {
                        if (text[j] == '\\' and j + 1 < text.len) j += 1;
                        try out.append(self.alloc(), text[j]);
                        j += 1;
                    }
                    i = j + 1;
                },
                '$' => {
                    if (i + 1 < text.len and (text[i + 1] == '\'' or text[i + 1] == '"')) {
                        quoted = true;
                        i += 1;
                    } else {
                        try out.append(self.alloc(), c);
                        i += 1;
                    }
                },
                else => {
                    try out.append(self.alloc(), c);
                    i += 1;
                },
            }
        }
        return .{ try out.toOwnedSlice(self.alloc()), quoted };
    }

    fn parse_redirect(self: *Parser, next_assign: bool) Error!ast.Redirect {
        var fd: ast.RedirFd = .none;
        if (self.tok.tag == .io_number) {
            fd = .{ .num = self.tok.num };
            try self.advance(false);
        } else if (self.tok.tag == .io_var) {
            fd = .{ .named = self.tok.name };
            try self.advance(false);
        }
        const op: ast.RedirOp = switch (self.tok.tag) {
            .less => .in,
            .great => .out,
            .dgreat => .append,
            .clobber => .clobber,
            .less_great => .read_write,
            .less_and => .dup_in,
            .great_and => .dup_out,
            .tless => .here_str,
            .dless => .heredoc,
            .dless_dash => .heredoc_strip,
            .and_great => .out_err,
            .and_dgreat => .append_err,
            else => return self.unexpected(),
        };
        try self.advance(false);
        if (self.tok.tag == .eof) return self.lex.fail_newline();
        if (self.tok.tag != .word) return self.unexpected();
        var r = ast.Redirect{ .fd = fd, .op = op, .target = self.cur_word() };
        if (op == .heredoc or op == .heredoc_strip) {
            const d = try self.heredoc_delim(self.lex.orig[self.tok.start..self.tok.end]);
            const h = try self.alloc().create(ast.Heredoc);
            h.* = .{ .delimiter = d[0], .quoted = d[1], .strip_tabs = op == .heredoc_strip };
            r.heredoc = h;
            try self.lex.pending.append(self.alloc(), h);
        }
        try self.advance(next_assign);
        return r;
    }

    fn is_decl_name(w: ast.Word) bool {
        const t = ast.word_is_plain_lit(w) orelse return false;
        const names = [_][]const u8{ "declare", "typeset", "local", "export", "readonly" };
        for (names) |n| if (std.mem.eql(u8, t, n)) return true;
        return false;
    }

    fn parse_simple(self: *Parser, line: u32) Error!ast.Command {
        const abase = self.assigns.items.len;
        const wbase = self.words.items.len;
        const rbase = self.redirs.items.len;
        var is_decl = false;
        while (true) {
            switch (self.tok.tag) {
                .assign => {
                    const t = self.tok;
                    if (self.words.items.len == wbase) {
                        try self.assigns.append(self.alloc(), t.assign.?.*);
                        try self.advance(true);
                    } else {
                        const w = try self.lex.assign_to_word(t);
                        try self.words.append(self.alloc(), w);
                        try self.advance(is_decl);
                    }
                },
                .word => {
                    const first = self.words.items.len == wbase;
                    const w = self.cur_word();
                    try self.words.append(self.alloc(), w);
                    if (first) {
                        is_decl = is_decl_name(w);
                        try self.advance(is_decl);
                        if (self.tok.tag == .lparen and self.assigns.items.len == abase and self.redirs.items.len == rbase) {
                            const name = ast.word_is_plain_lit(w) orelse return self.unexpected();
                            self.words.items.len = wbase;
                            return self.parse_function_def(name, false, line);
                        }
                    } else try self.advance(is_decl);
                },
                else => {
                    if (!is_redir_start(self.tok.tag)) break;
                    const r = try self.parse_redirect(self.words.items.len == wbase or is_decl);
                    try self.redirs.append(self.alloc(), r);
                },
            }
        }
        const na = self.assigns.items.len - abase;
        const nw = self.words.items.len - wbase;
        const nr = self.redirs.items.len - rbase;
        if (na == 0 and nw == 0 and nr == 0) return self.unexpected();
        const assigns: []const ast.Assign = if (na == 0) &.{} else try self.alloc().dupe(ast.Assign, self.assigns.items[abase..]);
        const words: []const ast.Word = if (nw == 0) &.{} else try self.alloc().dupe(ast.Word, self.words.items[wbase..]);
        const redirs: []const ast.Redirect = if (nr == 0) &.{} else try self.alloc().dupe(ast.Redirect, self.redirs.items[rbase..]);
        self.assigns.items.len = abase;
        self.words.items.len = wbase;
        self.redirs.items.len = rbase;
        return .{ .body = .{ .simple = .{ .assigns = assigns, .words = words } }, .redirs = redirs, .line = line };
    }

    fn is_compound_start(self: *Parser) bool {
        return switch (self.tok.tag) {
            .lparen => true,
            .word => switch (self.tok.kw) {
                .kw_if, .kw_while, .kw_until, .kw_for, .kw_select, .kw_case, .kw_lbrace, .kw_dlbracket => true,
                else => false,
            },
            else => false,
        };
    }

    fn parse_function_def(self: *Parser, name: []const u8, keyword: bool, line: u32) Error!ast.Command {
        if (self.tok.tag == .lparen) {
            try self.advance(false);
            if (self.tok.tag == .eof) return self.lex.fail_newline();
            if (self.tok.tag != .rparen) return self.unexpected();
            try self.advance(true);
        } else if (!keyword) return self.unexpected();
        try self.skip_newlines();
        if (!self.is_compound_start()) return self.unexpected();
        const body = try self.alloc().create(ast.Command);
        body.* = try self.parse_command();
        return .{ .body = .{ .function = .{ .name = name, .body = body, .keyword = keyword } }, .line = line };
    }

    fn parse_function_kw(self: *Parser) Error!ast.Command {
        const line = self.lex.line_at(self.tok.start);
        try self.advance(false);
        if (self.tok.tag == .eof) return self.lex.fail_newline();
        if (self.tok.tag != .word) return self.unexpected();
        const name = self.lex.orig[self.tok.start..self.tok.end];
        try self.advance(false);
        return self.parse_function_def(name, true, line);
    }

    fn parse_group(self: *Parser) Error!ast.Command {
        try self.advance(true);
        const list = try self.parse_list(true);
        try self.expect_kw(.kw_rbrace);
        return .{ .body = .{ .group = list } };
    }

    fn parse_subshell(self: *Parser) Error!ast.Command {
        const s: usize = self.tok.start;
        const src = self.lex.src;
        if (s + 1 < src.len and src[s + 1] == '(') {
            if (self.lex.find_arith_end(s + 2)) |end| {
                const e = try arith_parse.parse_region(&self.lex, s + 2, end);
                self.lex.pos = end + 2;
                try self.advance(true);
                return .{ .body = .{ .arith_cmd = e } };
            }
        }
        const double = s + 1 < src.len and src[s + 1] == '(';
        try self.advance(true);
        const list = self.parse_list(true) catch |e| return if (double) self.matching_on_eof(e, s) else e;
        if (self.tok.tag != .rparen) return self.unexpected();
        try self.advance(true);
        return .{ .body = .{ .subshell = list } };
    }

    fn parse_if(self: *Parser) Error!ast.Command {
        try self.advance(true);
        const base = self.clauses.items.len;
        var else_body: ?ast.List = null;
        while (true) {
            const cond = try self.parse_list(true);
            try self.expect_kw(.kw_then);
            const body = try self.parse_list(true);
            try self.clauses.append(self.alloc(), .{ .cond = cond, .body = body });
            if (self.is_kw(.kw_elif)) {
                try self.advance(true);
                continue;
            }
            if (self.is_kw(.kw_else)) {
                try self.advance(true);
                else_body = try self.parse_list(true);
            }
            break;
        }
        try self.expect_kw(.kw_fi);
        const clauses = try self.alloc().dupe(ast.IfClause, self.clauses.items[base..]);
        self.clauses.items.len = base;
        return .{ .body = .{ .if_cmd = .{ .clauses = clauses, .else_body = else_body } } };
    }

    fn parse_while(self: *Parser) Error!ast.Command {
        const until = self.tok.kw == .kw_until;
        try self.advance(true);
        const cond = try self.parse_list(true);
        try self.expect_kw(.kw_do);
        const body = try self.parse_list(true);
        try self.expect_kw(.kw_done);
        return .{ .body = .{ .loop = .{ .cond = cond, .body = body, .until = until } } };
    }

    fn parse_for(self: *Parser, is_select: bool) Error!ast.Command {
        try self.advance(false);
        if (!is_select and self.tok.tag == .lparen and self.tok.end < self.lex.src.len and self.lex.src[self.tok.end] == '(') {
            return self.parse_arith_for();
        }
        if (self.tok.tag != .word) return self.unexpected();
        const name = self.lex.orig[self.tok.start..self.tok.end];
        try self.advance(false);
        try self.skip_newlines();
        var words: ?[]const ast.Word = null;
        if (self.is_kw(.kw_in)) {
            try self.advance(false);
            const base = self.words.items.len;
            while (self.tok.tag == .word) {
                try self.words.append(self.alloc(), self.cur_word());
                try self.advance(false);
            }
            if (self.tok.tag != .semi and self.tok.tag != .newline) return self.unexpected();
            try self.advance(true);
            try self.skip_newlines();
            words = try self.alloc().dupe(ast.Word, self.words.items[base..]);
            self.words.items.len = base;
        } else if (self.tok.tag == .semi) {
            try self.advance(true);
            try self.skip_newlines();
        }
        const body = try self.parse_loop_body();
        const fi = ast.ForIn{ .name = name, .words = words, .body = body };
        return .{ .body = if (is_select) .{ .select = fi } else .{ .for_in = fi } };
    }

    fn parse_loop_body(self: *Parser) Error!ast.List {
        if (self.is_kw(.kw_lbrace)) {
            try self.advance(true);
            const body = try self.parse_list(true);
            try self.expect_kw(.kw_rbrace);
            return body;
        }
        try self.expect_kw(.kw_do);
        const body = try self.parse_list(true);
        try self.expect_kw(.kw_done);
        return body;
    }

    fn parse_arith_for(self: *Parser) Error!ast.Command {
        const s: usize = self.tok.start;
        const lx = &self.lex;
        const end = lx.find_arith_end(s + 2) orelse return self.unexpected();
        var exprs: [3]?*const ast.Arith = .{ null, null, null };
        {
            const saved = lx.src;
            lx.src = saved[0..end];
            defer lx.src = saved;
            var pos = s + 2;
            for (0..3) |i| {
                var stop = end;
                if (i < 2) {
                    stop = lx.extent(pos, ';', ';') orelse return lx.fail_arith_for("arithmetic expression required", s, end + 2);
                } else if (lx.extent(pos, ';', ';') != null) {
                    return lx.fail_arith_for("`;' unexpected", s, end + 2);
                }
                const text = lx.src[pos..stop];
                if (std.mem.trim(u8, text, " \t\n").len > 0) exprs[i] = try arith_parse.parse_region(lx, pos, stop);
                pos = stop + 1;
            }
        }
        lx.pos = end + 2;
        try self.advance(true);
        if (self.tok.tag == .semi) try self.advance(true);
        try self.skip_newlines();
        const body = try self.parse_loop_body();
        return .{ .body = .{ .arith_for = .{ .init = exprs[0], .cond = exprs[1], .step = exprs[2], .body = body } } };
    }

    fn parse_case(self: *Parser) Error!ast.Command {
        try self.advance(false);
        if (self.tok.tag != .word) return self.unexpected();
        const subject = self.cur_word();
        try self.advance(false);
        try self.skip_newlines();
        if (!self.is_kw(.kw_in)) return self.unexpected();
        try self.advance(false);
        const base = self.case_clauses.items.len;
        while (true) {
            while (self.tok.tag == .newline) try self.advance(false);
            if (self.is_kw(.kw_esac)) break;
            if (self.tok.tag == .lparen) try self.advance(false);
            const wbase = self.words.items.len;
            while (true) {
                if (self.tok.tag != .word) return self.unexpected();
                try self.words.append(self.alloc(), self.cur_word());
                try self.advance(false);
                if (self.tok.tag == .pipe) {
                    try self.advance(false);
                    continue;
                }
                break;
            }
            if (self.tok.tag != .rparen) return self.unexpected();
            const patterns = try self.alloc().dupe(ast.Word, self.words.items[wbase..]);
            self.words.items.len = wbase;
            try self.advance(true);
            const body = try self.parse_list(false);
            var term: ast.CaseTerm = .break_;
            var terminated = true;
            switch (self.tok.tag) {
                .dsemi => {
                    try self.advance(false);
                },
                .semi_amp => {
                    term = .fallthrough;
                    try self.advance(false);
                },
                .dsemi_amp => {
                    term = .test_next;
                    try self.advance(false);
                },
                else => terminated = false,
            }
            try self.case_clauses.append(self.alloc(), .{ .patterns = patterns, .body = body, .term = term });
            if (self.is_kw(.kw_esac)) break;
            if (!terminated) return self.unexpected();
        }
        try self.expect_kw(.kw_esac);
        const clauses = try self.alloc().dupe(ast.CaseClause, self.case_clauses.items[base..]);
        self.case_clauses.items.len = base;
        return .{ .body = .{ .case = .{ .word = subject, .clauses = clauses } } };
    }

    fn peek_second_starts_compound(self: *Parser) Error!bool {
        const saved_pos = self.lex.pos;
        const saved_nh = self.lex.no_heredoc;
        self.lex.no_heredoc = true;
        defer {
            self.lex.pos = saved_pos;
            self.lex.no_heredoc = saved_nh;
        }
        const t = try self.lex.next(false);
        return switch (t.tag) {
            .lparen => true,
            .word => switch (t.kw) {
                .kw_if, .kw_while, .kw_until, .kw_for, .kw_select, .kw_case, .kw_lbrace, .kw_dlbracket => true,
                else => false,
            },
            else => false,
        };
    }

    fn parse_coproc(self: *Parser) Error!ast.Command {
        try self.advance(false);
        if (self.tok.tag == .eof) return self.lex.fail_newline();
        var name: ?[]const u8 = null;
        if (self.tok.tag == .word and self.tok.kw == .none and try self.peek_second_starts_compound()) {
            name = self.lex.orig[self.tok.start..self.tok.end];
            try self.advance(true);
        }
        const body = try self.alloc().create(ast.Command);
        body.* = try self.parse_command();
        return .{ .body = .{ .coproc = .{ .name = name, .body = body } } };
    }

    fn unary_op(text: []const u8) ?ast.CondUnary {
        if (text.len != 2 or text[0] != '-') return null;
        return std.meta.stringToEnum(ast.CondUnary, text[1..]);
    }

    fn binary_op(self: *Parser) ?ast.CondBinary {
        switch (self.tok.tag) {
            .less => return .lt,
            .great => return .gt,
            .word => {
                const t = ast.word_is_plain_lit(self.cur_word()) orelse return null;
                const table = [_]struct { []const u8, ast.CondBinary }{
                    .{ "==", .eq2 },
                    .{ "=", .eq },
                    .{ "!=", .ne },
                    .{ "=~", .match },
                    .{ "-eq", .int_eq },
                    .{ "-ne", .int_ne },
                    .{ "-lt", .int_lt },
                    .{ "-le", .int_le },
                    .{ "-gt", .int_gt },
                    .{ "-ge", .int_ge },
                    .{ "-nt", .nt },
                    .{ "-ot", .ot },
                    .{ "-ef", .ef },
                };
                for (table) |e| if (std.mem.eql(u8, t, e[0])) return e[1];
                return null;
            },
            else => return null,
        }
    }

    fn mk_cond(self: *Parser, c: ast.Cond) Allocator.Error!*const ast.Cond {
        const n = try self.alloc().create(ast.Cond);
        n.* = c;
        return n;
    }

    fn tok_text(self: *Parser, t: Token) []const u8 {
        return if (t.tag == .newline or t.tag == .eof) "newline" else self.lex.orig[t.start..t.end];
    }

    fn cond_fail(self: *Parser, comptime fmt: []const u8, args: anytype, near: Token) Error {
        const detail = std.fmt.allocPrint(self.alloc(), fmt, args) catch return error.OutOfMemory;
        return self.lex.fail_cond(detail, near);
    }

    fn parse_cond_command(self: *Parser) Error!ast.Command {
        const open = self.tok.start;
        try self.cond_advance(false);
        const c = try self.parse_cond_or(open);
        if (!self.is_kw(.kw_drbracket)) {
            if (self.tok.tag == .eof) return self.lex.fail_looking("]]", open);
            if (self.tok.tag == .word) return self.lex.fail_cond("syntax error in conditional expression", self.tok);
            return self.cond_fail("syntax error in conditional expression: unexpected token `{s}'", .{self.tok_text(self.tok)}, self.tok);
        }
        try self.advance(true);
        return .{ .body = .{ .cond = c } };
    }

    fn parse_cond_or(self: *Parser, open: usize) Error!*const ast.Cond {
        var l = try self.parse_cond_and(open);
        while (self.tok.tag == .or_if) {
            try self.cond_advance(false);
            const r = try self.parse_cond_and(open);
            l = try self.mk_cond(.{ .or_ = .{ .lhs = l, .rhs = r } });
        }
        return l;
    }

    fn parse_cond_and(self: *Parser, open: usize) Error!*const ast.Cond {
        var l = try self.parse_cond_not(open);
        while (self.tok.tag == .and_if) {
            try self.cond_advance(false);
            const r = try self.parse_cond_not(open);
            l = try self.mk_cond(.{ .and_ = .{ .lhs = l, .rhs = r } });
        }
        return l;
    }

    fn parse_cond_not(self: *Parser, open: usize) Error!*const ast.Cond {
        self.lex.depth += 1;
        defer self.lex.depth -= 1;
        if (self.lex.depth > lexer.max_depth) return self.lex.fail_nesting();
        if (self.is_kw(.kw_bang)) {
            try self.cond_advance(false);
            const e = try self.parse_cond_not(open);
            return self.mk_cond(.{ .not = e });
        }
        return self.parse_cond_primary(open);
    }

    fn cond_operand_ok(self: *Parser) bool {
        return self.tok.tag == .word and self.tok.kw != .kw_drbracket;
    }

    fn parse_cond_primary(self: *Parser, open: usize) Error!*const ast.Cond {
        if (self.tok.tag == .lparen) {
            try self.cond_advance(false);
            const e = try self.parse_cond_or(open);
            if (self.tok.tag != .rparen) {
                if (self.tok.tag == .eof) return self.lex.fail_looking("]]", open);
                return self.cond_fail("unexpected token `{s}', expected `)'", .{self.tok_text(self.tok)}, self.tok);
            }
            try self.cond_advance(false);
            return self.mk_cond(.{ .group = e });
        }
        if (self.tok.tag == .eof) return self.lex.fail_looking("]]", open);
        if (self.tok.tag == .or_if or self.tok.tag == .and_if) {
            var near = self.tok;
            near.end = near.start + 1;
            return self.cond_fail("unexpected token `{s}' in conditional command", .{self.tok_text(self.tok)}, near);
        }
        if (self.tok.tag != .word) return self.cond_fail("syntax error in conditional expression: unexpected token `{s}'", .{self.tok_text(self.tok)}, self.tok);
        if (self.tok.kw == .kw_drbracket) return self.lex.fail_cond("", self.tok);
        const first = self.cur_word();
        const first_tok = self.tok;
        try self.cond_advance(false);
        if (ast.word_is_plain_lit(first)) |t| {
            if (unary_op(t)) |u| {
                if (self.cond_operand_ok() and self.binary_op() == null) {
                    const arg = self.cur_word();
                    try self.cond_advance(false);
                    return self.mk_cond(.{ .unary = .{ .op = u, .arg = arg } });
                }
                if (self.binary_op() == null) {
                    const near = if (self.tok.tag == .eof) first_tok else self.tok;
                    return self.cond_fail("unexpected argument `{s}' to conditional unary operator", .{self.tok_text(self.tok)}, near);
                }
            }
        }
        if (self.binary_op()) |op| {
            const op_tok = self.tok;
            try self.cond_advance(op == .match);
            if (!self.cond_operand_ok()) {
                const near = if (self.tok.tag == .eof) op_tok else self.tok;
                return self.cond_fail("unexpected argument `{s}' to conditional binary operator", .{self.tok_text(self.tok)}, near);
            }
            const rhs = self.cur_word();
            try self.cond_advance(false);
            return self.mk_cond(.{ .binary = .{ .op = op, .lhs = first, .rhs = rhs } });
        }
        if (self.cond_operand_ok()) return self.cond_fail("conditional binary operator expected", .{}, self.tok);
        if (self.tok.tag == .eof) return self.cond_fail("unexpected token `newline', conditional binary operator expected", .{}, first_tok);
        return self.mk_cond(.{ .word = first });
    }
};

const dump = @import("ast_dump.zig");

fn expect_dump(src: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (parse(arena.allocator(), src, .{})) {
        .ok => |list| {
            const got = try dump.dump_alloc(arena.allocator(), list);
            std.testing.expectEqualStrings(want, got) catch |e| {
                std.debug.print("src: {s}\n", .{src});
                return e;
            };
        },
        .err => |e| {
            var buf: [512]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            e.write(&w, "zash") catch {};
            std.debug.print("src: {s}\nunexpected error: {s}\n", .{ src, w.buffered() });
            return error.TestUnexpectedResult;
        },
    }
}

fn expect_error(src: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (parse(arena.allocator(), src, .{})) {
        .ok => {
            std.debug.print("src: {s}\nexpected a syntax error\n", .{src});
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            var buf: [2048]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try e.write(&w, "zash: -c");
            std.testing.expectEqualStrings(want, w.buffered()) catch |err| {
                std.debug.print("src: {s}\n", .{src});
                return err;
            };
        },
    }
}

test "dump lists and pipelines" {
    const cases = [_][2][]const u8{
        .{ "echo hello world", "(list (cmd \"echo\" \"hello\" \"world\"))" },
        .{ "echo a;echo b", "(list (cmd \"echo\" \"a\") (cmd \"echo\" \"b\"))" },
        .{ "echo a & echo b", "(list (& (cmd \"echo\" \"a\")) (cmd \"echo\" \"b\"))" },
        .{ "a && b || c", "(list (&& (|| (cmd \"a\") (cmd \"b\")) (cmd \"c\")))" },
        .{ "a || b && c", "(list (|| (&& (cmd \"a\") (cmd \"b\")) (cmd \"c\")))" },
        .{ "a && b && c", "(list (&& (&& (cmd \"a\") (cmd \"b\")) (cmd \"c\")))" },
        .{ "a | b | c", "(list (pipe (cmd \"a\") | (cmd \"b\") | (cmd \"c\")))" },
        .{ "a |& b | c", "(list (pipe (cmd \"a\") |& (cmd \"b\") | (cmd \"c\")))" },
        .{ "! a | b", "(list (! (pipe (cmd \"a\") | (cmd \"b\"))))" },
        .{ "! ! a", "(list (cmd \"a\"))" },
        .{ "time a | b", "(list (time (pipe (cmd \"a\") | (cmd \"b\"))))" },
        .{ "time -p a", "(list (time-p (cmd \"a\")))" },
        .{ "time", "(list (time (empty)))" },
        .{ "time ! a", "(list (! (time (cmd \"a\"))))" },
        .{ "a &", "(list (& (cmd \"a\")))" },
        .{ "a & b &", "(list (& (cmd \"a\")) (& (cmd \"b\")))" },
        .{ "a;", "(list (cmd \"a\"))" },
        // error case skipped: 'a;;'
        .{ "( a; b )", "(list (sub (list (cmd \"a\") (cmd \"b\"))))" },
        .{ "(a)&", "(list (& (sub (list (cmd \"a\")))))" },
        .{ "{ a; b; }", "(list (grp (list (cmd \"a\") (cmd \"b\"))))" },
        .{ "{ a; } > f 2>&1", "(list (R (grp (list (cmd \"a\"))) (r > \"f\") (r 2 >& \"1\")))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump compound commands" {
    const cases = [_][2][]const u8{
        .{ "if a; then b; fi", "(list (if (list (cmd \"a\")) (list (cmd \"b\"))))" },
        .{ "if a; then b; else c; fi", "(list (if (list (cmd \"a\")) (list (cmd \"b\")) (else (list (cmd \"c\")))))" },
        .{ "if a; then b; elif c; then d; elif e; then f; else g; fi", "(list (if (list (cmd \"a\")) (list (cmd \"b\")) (elif (list (cmd \"c\")) (list (cmd \"d\"))) (elif (list (cmd \"e\")) (list (cmd \"f\"))) (else (list (cmd \"g\")))))" },
        .{ "if a\nthen\n  b\nfi", "(list (if (list (cmd \"a\")) (list (cmd \"b\"))))" },
        .{ "if a; then b; fi | c", "(list (pipe (if (list (cmd \"a\")) (list (cmd \"b\"))) | (cmd \"c\")))" },
        .{ "if ! a; then b; fi", "(list (if (list (! (cmd \"a\"))) (list (cmd \"b\"))))" },
        .{ "while a; do b; done", "(list (while (list (cmd \"a\")) (list (cmd \"b\"))))" },
        .{ "until a; do b; done", "(list (until (list (cmd \"a\")) (list (cmd \"b\"))))" },
        .{ "while a && b; do c; d; done", "(list (while (list (&& (cmd \"a\") (cmd \"b\"))) (list (cmd \"c\") (cmd \"d\"))))" },
        .{ "for i in 1 2 3; do echo $i; done", "(list (for \"i\" (in \"1\" \"2\" \"3\") (list (cmd \"echo\" (w (v i))))))" },
        .{ "for i in; do :; done", "(list (for \"i\" (in) (list (cmd \":\"))))" },
        .{ "for i; do :; done", "(list (for \"i\" (list (cmd \":\"))))" },
        .{ "for i in $(ls) \"a b\" *.c; do :; done", "(list (for \"i\" (in (w (cs (list (cmd \"ls\")))) (w (dq \"a b\")) \"*.c\") (list (cmd \":\"))))" },
        .{ "for i\nin a b\ndo :\ndone", "(list (for \"i\" (in \"a\" \"b\") (list (cmd \":\"))))" },
        .{ "for ((i=0;i<3;i++)); do echo $i; done", "(list (for-arith (= i 0) (< i 3) (post++ i) (list (cmd \"echo\" (w (v i))))))" },
        .{ "for ((;;)); do break; done", "(list (for-arith _ _ _ (list (cmd \"break\"))))" },
        .{ "for ((i=0, j=10; i<j; i++, j--)) do :; done", "(list (for-arith (, (= i 0) (= j 10)) (< i j) (, (post++ i) (post-- j)) (list (cmd \":\"))))" },
        .{ "select x in a b; do break; done", "(list (select \"x\" (in \"a\" \"b\") (list (cmd \"break\"))))" },
        .{ "select x; do break; done", "(list (select \"x\" (list (cmd \"break\"))))" },
        .{ "case x in a) echo a;; b|c) echo bc;; *) echo other;; esac", "(list (case \"x\" ((\"a\") (list (cmd \"echo\" \"a\"))) ((\"b\" \"c\") (list (cmd \"echo\" \"bc\"))) ((\"*\") (list (cmd \"echo\" \"other\")))))" },
        .{ "case x in a) echo a ;& b) echo b ;;& c) : ;; esac", "(list (case \"x\" ((\"a\") (list (cmd \"echo\" \"a\")) ;&) ((\"b\") (list (cmd \"echo\" \"b\")) ;;&) ((\"c\") (list (cmd \":\")))))" },
        .{ "case x in (a) :;; (b|c) :;; esac", "(list (case \"x\" ((\"a\") (list (cmd \":\"))) ((\"b\" \"c\") (list (cmd \":\")))))" },
        .{ "case x in esac", "(list (case \"x\"))" },
        .{ "case x in a) ;; esac", "(list (case \"x\" ((\"a\") (list))))" },
        .{ "case \"$x\" in 'a b'|\"c d\"|e*f|[0-9]*) : ;; esac", "(list (case (w (dq (v x))) (((w (q \"a b\")) (w (dq \"c d\")) \"e*f\" \"[0-9]*\") (list (cmd \":\")))))" },
        // error case skipped: 'case x in a) echo a esac'
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump functions" {
    const cases = [_][2][]const u8{
        .{ "f() { echo hi; }", "(list (fn \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
        .{ "f ( ) { echo hi; }", "(list (fn \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
        .{ "f() ( echo hi )", "(list (fn \"f\" (sub (list (cmd \"echo\" \"hi\")))))" },
        .{ "f() if a; then b; fi", "(list (fn \"f\" (if (list (cmd \"a\")) (list (cmd \"b\")))))" },
        .{ "f() [[ a ]]", "(list (fn \"f\" (cond \"a\")))" },
        .{ "f() { :; } > /dev/null", "(list (fn \"f\" (R (grp (list (cmd \":\"))) (r > \"/dev/null\"))))" },
        .{ "function f { echo hi; }", "(list (fn-kw \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
        .{ "function f() { echo hi; }", "(list (fn-kw \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
        .{ "function f ( ) { echo hi; }", "(list (fn-kw \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
        .{ "function f\n{\n  echo hi\n}", "(list (fn-kw \"f\" (grp (list (cmd \"echo\" \"hi\")))))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump conditionals" {
    const cases = [_][2][]const u8{
        .{ "[[ a == b ]]", "(list (cond (== \"a\" \"b\")))" },
        .{ "[[ a = b ]]", "(list (cond (= \"a\" \"b\")))" },
        .{ "[[ a != b ]]", "(list (cond (!= \"a\" \"b\")))" },
        .{ "[[ a < b ]]", "(list (cond (< \"a\" \"b\")))" },
        .{ "[[ a > b ]]", "(list (cond (> \"a\" \"b\")))" },
        .{ "[[ -f x ]]", "(list (cond (-f \"x\")))" },
        .{ "[[ -n $x && -z $y ]]", "(list (cond (&& (-n (w (v x))) (-z (w (v y))))))" },
        .{ "[[ -f x || -d y && -e z ]]", "(list (cond (|| (-f \"x\") (&& (-d \"y\") (-e \"z\")))))" },
        .{ "[[ ! -f x ]]", "(list (cond (! (-f \"x\"))))" },
        .{ "[[ ( a == b || c == d ) && e ]]", "(list (cond (&& (grp (|| (== \"a\" \"b\") (== \"c\" \"d\"))) \"e\")))" },
        .{ "[[ $a =~ ^[0-9]+$ ]]", "(list (cond (=~ (w (v a)) \"^[0-9]+$\")))" },
        .{ "[[ $a =~ (a|b)+ ]]", "(list (cond (=~ (w (v a)) \"(a|b)+\")))" },
        .{ "[[ a -eq 1 && b -ne 2 && c -lt 3 && d -le 4 && e -gt 5 && f -ge 6 ]]", "(list (cond (&& (&& (&& (&& (&& (-eq \"a\" \"1\") (-ne \"b\" \"2\")) (-lt \"c\" \"3\")) (-le \"d\" \"4\")) (-gt \"e\" \"5\")) (-ge \"f\" \"6\"))))" },
        .{ "[[ a -nt b || a -ot b || a -ef b ]]", "(list (cond (|| (|| (-nt \"a\" \"b\") (-ot \"a\" \"b\")) (-ef \"a\" \"b\"))))" },
        .{ "[[ a == @(x|y) ]]", "(list (cond (== \"a\" \"@(x|y)\")))" },
        .{ "[[ a == \"x y\" ]]", "(list (cond (== \"a\" (w (dq \"x y\")))))" },
        .{ "[[ -v x ]]", "(list (cond (-v \"x\")))" },
        .{ "[[ word ]]", "(list (cond \"word\"))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump arithmetic commands" {
    const cases = [_][2][]const u8{
        .{ "(( 1 + 2 ))", "(list (arith-cmd (+ 1 2)))" },
        .{ "(( x = 5, y = x * 2 ))", "(list (arith-cmd (, (= x 5) (= y (* x 2)))))" },
        .{ "(( x++ ))", "(list (arith-cmd (post++ x)))" },
        .{ "((x<3)) && echo y", "(list (&& (arith-cmd (< x 3)) (cmd \"echo\" \"y\")))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump assignments" {
    const cases = [_][2][]const u8{
        .{ "a=1", "(list (cmd (= a \"1\")))" },
        .{ "a=1 b=2 cmd arg", "(list (cmd (= a \"1\") (= b \"2\") \"cmd\" \"arg\"))" },
        .{ "a=1 b=2", "(list (cmd (= a \"1\") (= b \"2\")))" },
        .{ "a=", "(list (cmd (= a (w))))" },
        .{ "a= cmd", "(list (cmd (= a (w)) \"cmd\"))" },
        .{ "a=$b", "(list (cmd (= a (w (v b)))))" },
        .{ "a=\"x y\"", "(list (cmd (= a (w (dq \"x y\")))))" },
        .{ "a=$(cmd)", "(list (cmd (= a (w (cs (list (cmd \"cmd\")))))))" },
        .{ "a=~/x", "(list (cmd (= a (w (tilde \"\") \"/x\"))))" },
        .{ "a=~:~/x", "(list (cmd (= a (w (tilde \"\") \":\" (tilde \"\") \"/x\"))))" },
        .{ "a=(1 2 3)", "(list (cmd (= a (arr \"1\" \"2\" \"3\"))))" },
        .{ "a=()", "(list (cmd (= a (arr))))" },
        .{ "a=(1 [5]=2 \"x y\" $b)", "(list (cmd (= a (arr \"1\" (kv \"5\" \"2\") (w (dq \"x y\")) (w (v b))))))" },
        .{ "a+=(4 5)", "(list (cmd (+= a (arr \"4\" \"5\"))))" },
        .{ "a+=x", "(list (cmd (+= a \"x\")))" },
        .{ "a[1]=x", "(list (cmd (= a[\"1\"] \"x\")))" },
        .{ "a[i+1]=x", "(list (cmd (= a[\"i+1\"] \"x\")))" },
        .{ "a[1]+=x", "(list (cmd (+= a[\"1\"] \"x\")))" },
        .{ "a=([x]=1 [y]=2)", "(list (cmd (= a (arr (kv \"x\" \"1\") (kv \"y\" \"2\")))))" },
        .{ "a=(\n1\n2 # c\n3\n)", "(list (cmd (= a (arr \"1\" \"2\" \"3\"))))" },
        .{ "declare -a arr=(1 2 3)", "(list (cmd \"declare\" \"-a\" (w \"arr=\" (arr \"1\" \"2\" \"3\"))))" },
        .{ "local x=1 y=(a b)", "(list (cmd \"local\" (w \"x=\" \"1\") (w \"y=\" (arr \"a\" \"b\"))))" },
        .{ "export A=1 B=$(c)", "(list (cmd \"export\" (w \"A=\" \"1\") (w \"B=\" (cs (list (cmd \"c\"))))))" },
        .{ "echo a=b c=d", "(list (cmd \"echo\" \"a=b\" \"c=d\"))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump redirections" {
    const cases = [_][2][]const u8{
        .{ "cmd > f", "(list (cmd \"cmd\" (r > \"f\")))" },
        .{ "cmd >> f", "(list (cmd \"cmd\" (r >> \"f\")))" },
        .{ "cmd < f", "(list (cmd \"cmd\" (r < \"f\")))" },
        .{ "cmd 2> f", "(list (cmd \"cmd\" (r 2 > \"f\")))" },
        .{ "cmd 2>&1", "(list (cmd \"cmd\" (r 2 >& \"1\")))" },
        .{ "cmd >&2", "(list (cmd \"cmd\" (r >& \"2\")))" },
        .{ "cmd 1>&2", "(list (cmd \"cmd\" (r 1 >& \"2\")))" },
        .{ "cmd &> f", "(list (cmd \"cmd\" (r &> \"f\")))" },
        .{ "cmd &>> f", "(list (cmd \"cmd\" (r &>> \"f\")))" },
        .{ "cmd <<< word", "(list (cmd \"cmd\" (r <<< \"word\")))" },
        .{ "cmd <<< \"a b $c\"", "(list (cmd \"cmd\" (r <<< (w (dq \"a b \" (v c))))))" },
        .{ "cmd <> f", "(list (cmd \"cmd\" (r <> \"f\")))" },
        .{ "cmd >| f", "(list (cmd \"cmd\" (r >| \"f\")))" },
        .{ "cmd {fd}> f", "(list (cmd \"cmd\" (r {fd} > \"f\")))" },
        .{ "cmd {fd}>&-", "(list (cmd \"cmd\" (r {fd} >& \"-\")))" },
        .{ "cmd 2>&-", "(list (cmd \"cmd\" (r 2 >& \"-\")))" },
        .{ "cmd <&0", "(list (cmd \"cmd\" (r <& \"0\")))" },
        .{ "cmd 3< f 4> g", "(list (cmd \"cmd\" (r 3 < \"f\") (r 4 > \"g\")))" },
        .{ "> f", "(list (cmd (r > \"f\")))" },
        .{ ">f cmd arg", "(list (cmd \"cmd\" \"arg\" (r > \"f\")))" },
        .{ "cmd >f arg >g", "(list (cmd \"cmd\" \"arg\" (r > \"f\") (r > \"g\")))" },
        .{ "cmd 10>f", "(list (cmd \"cmd\" (r 10 > \"f\")))" },
        .{ "cmd 2>/dev/null | cat", "(list (pipe (cmd \"cmd\" (r 2 > \"/dev/null\")) | (cmd \"cat\")))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump heredocs" {
    const cases = [_][2][]const u8{
        .{ "cat <<EOF\nhello $x\n`date`\n$(cmd)\n\\$notvar\nEOF", "(list (cmd \"cat\" (r << \"EOF\" u (w \"hello \" (v x) \"\\n\" (bt (list (cmd \"date\"))) \"\\n\" (cs (list (cmd \"cmd\"))) \"\\n$notvar\\n\"))))" },
        .{ "cat <<EOF\nEOF", "(list (cmd \"cat\" (r << \"EOF\" u (w))))" },
        .{ "cat <<-EOF\n\thello\n\t\tthere\n\tEOF", "(list (cmd \"cat\" (r <<- \"EOF\" u (w \"hello\\nthere\\n\"))))" },
        .{ "cat <<'EOF'\n$x `y`\nEOF", "(list (cmd \"cat\" (r << \"EOF\" q (w (q \"$x `y`\\n\")))))" },
        .{ "cat <<\"EOF\"\n$x\nEOF", "(list (cmd \"cat\" (r << \"EOF\" q (w (q \"$x\\n\")))))" },
        .{ "cat <<\\EOF\n$x\nEOF", "(list (cmd \"cat\" (r << \"EOF\" q (w (q \"$x\\n\")))))" },
        .{ "cat <<EOF1 <<EOF2\na\nEOF1\nb\nEOF2", "(list (cmd \"cat\" (r << \"EOF1\" u (w \"a\\n\")) (r << \"EOF2\" u (w \"b\\n\"))))" },
        .{ "cat <<EOF | wc -l\na\nb\nEOF", "(list (pipe (cmd \"cat\" (r << \"EOF\" u (w \"a\\nb\\n\"))) | (cmd \"wc\" \"-l\")))" },
        .{ "cat <<EOF && echo done\na\nEOF", "(list (&& (cmd \"cat\" (r << \"EOF\" u (w \"a\\n\"))) (cmd \"echo\" \"done\")))" },
        .{ "echo \"$(cat <<EOF\nx\nEOF\n)\"", "(list (cmd \"echo\" (w (dq (cs (list (cmd \"cat\" (r << \"EOF\" u (w \"x\\n\")))))))))" },
        .{ "cat <<EOF\na\\\nb\nEOF", "(list (cmd \"cat\" (r << \"EOF\" u (w \"ab\\n\"))))" },
        .{ "cat <<EOF\na\nEOF\necho after", "(list (cmd \"cat\" (r << \"EOF\" u (w \"a\\n\"))) (cmd \"echo\" \"after\"))" },
        .{ "cat <<EOF\nno terminator", "(list (cmd \"cat\" (r << \"EOF\" u (w \"no terminator\"))))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump parameter expansion" {
    const cases = [_][2][]const u8{
        .{ "echo ${x}", "(list (cmd \"echo\" (w (v x))))" },
        .{ "echo ${x:-y} ${x:=y} ${x:?y} ${x:+y}", "(list (cmd \"echo\" (w (p x (:- \"y\"))) (w (p x (:= \"y\"))) (w (p x (:? \"y\"))) (w (p x (:+ \"y\")))))" },
        .{ "echo ${x-y} ${x=y} ${x?y} ${x+y}", "(list (cmd \"echo\" (w (p x (- \"y\"))) (w (p x (= \"y\"))) (w (p x (? \"y\"))) (w (p x (+ \"y\")))))" },
        .{ "echo ${x:-} ${x:-a b} ${x:-\"a b\"} ${x:-'a b'} ${x:-$y} ${x:-${y:-z}}", "(list (cmd \"echo\" (w (p x (:- (w)))) (w (p x (:- \"a b\"))) (w (p x (:- (w (dq \"a b\"))))) (w (p x (:- (w (q \"a b\"))))) (w (p x (:- (w (v y))))) (w (p x (:- (w (p y (:- \"z\"))))))))" },
        .{ "echo \"${x:-'a'}\"", "(list (cmd \"echo\" (w (dq (p x (:- \"'a'\"))))))" },
        .{ "echo ${#x} ${#} ${#1} ${#@} ${#x[@]} ${#x[1]}", "(list (cmd \"echo\" (w (p len x)) (w (v #)) (w (p len 1)) (w (p len @)) (w (p len x[@])) (w (p len x[\"1\"]))))" },
        .{ "echo ${!x} ${!x[@]} ${!x[*]} ${!pre*} ${!pre@}", "(list (cmd \"echo\" (w (p ind x)) (w (p ind x[@])) (w (p ind x[*])) (w (p ind pre (names *))) (w (p ind pre (names @)))))" },
        .{ "echo ${x[@]} ${x[*]} ${x[1]} ${x[$i]} ${x[\"k\"]} ${x[i+1]}", "(list (cmd \"echo\" (w (p x[@])) (w (p x[*])) (w (p x[\"1\"])) (w (p x[(w (v i))])) (w (p x[(w (dq \"k\"))])) (w (p x[\"i+1\"]))))" },
        .{ "echo ${x%y} ${x%%y} ${x#y} ${x##y} ${x%.*} ${x##*/}", "(list (cmd \"echo\" (w (p x (% \"y\"))) (w (p x (%% \"y\"))) (w (p x (# \"y\"))) (w (p x (## \"y\"))) (w (p x (% \".*\"))) (w (p x (## \"*/\")))))" },
        .{ "echo ${x/y/z} ${x//y/z} ${x/#y/z} ${x/%y/z} ${x/y} ${x//y} ${x/y/}", "(list (cmd \"echo\" (w (p x (/ \"y\" \"z\"))) (w (p x (// \"y\" \"z\"))) (w (p x (/# \"y\" \"z\"))) (w (p x (/% \"y\" \"z\"))) (w (p x (/ \"y\"))) (w (p x (// \"y\"))) (w (p x (/ \"y\" (w))))))" },
        .{ "echo ${x//[/]/_}", "(list (cmd \"echo\" (w (p x (// \"[\" \"]/_\")))))" },
        .{ "echo ${x^} ${x^^} ${x,} ${x,,} ${x^^[aeiou]}", "(list (cmd \"echo\" (w (p x (^))) (w (p x (^^))) (w (p x (,))) (w (p x (,,))) (w (p x (^^ \"[aeiou]\")))))" },
        .{ "echo ${x:1} ${x:1:2} ${x: -1} ${x:1:-1} ${x:$a:$b} ${x:a+1:b*2}", "(list (cmd \"echo\" (w (p x (sub 1))) (w (p x (sub 1 2))) (w (p x (sub (neg 1)))) (w (p x (sub 1 (neg 1)))) (w (p x (sub (exp (w (v a))) (exp (w (v b)))))) (w (p x (sub (+ a 1) (* b 2))))))" },
        .{ "echo ${x[@]:1:2}", "(list (cmd \"echo\" (w (p x[@] (sub 1 2)))))" },
        .{ "echo ${x@Q} ${x@E} ${x@P} ${x@A} ${x@a} ${x@U} ${x@u} ${x@L}", "(list (cmd \"echo\" (w (p x (@ Q))) (w (p x (@ E))) (w (p x (@ P))) (w (p x (@ A))) (w (p x (@ a))) (w (p x (@ U))) (w (p x (@ u))) (w (p x (@ L)))))" },
        .{ "echo ${1} ${10} ${@} ${*} ${?} ${-} ${$} ${!} ${_}", "(list (cmd \"echo\" (w (v 1)) (w (v 10)) (w (v @)) (w (v *)) (w (v ?)) (w (v -)) (w (v $)) (w (v !)) (w (v _))))" },
        .{ "echo $x $1 $@ $* $# $? $- $$ $! $0 $_ $x_y1", "(list (cmd \"echo\" (w (v x)) (w (v 1)) (w (v @)) (w (v *)) (w (v #)) (w (v ?)) (w (v -)) (w (v $)) (w (v !)) (w (v 0)) (w (v _)) (w (v x_y1))))" },
        .{ "echo $", "(list (cmd \"echo\" \"$\"))" },
        .{ "echo \"$\"", "(list (cmd \"echo\" (w (dq \"$\"))))" },
        .{ "echo $x.y $x-y ${x}y", "(list (cmd \"echo\" (w (v x) \".y\") (w (v x) \"-y\") (w (v x) \"y\")))" },
        .{ "echo ${}", "(list (cmd \"echo\" (w (bad \"${}\"))))" },
        .{ "echo ${x@}", "(list (cmd \"echo\" (w (bad \"${x@}\"))))" },
        .{ "echo ${x:}", "(list (cmd \"echo\" (w (p x (sub 0)))))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump substitutions" {
    const cases = [_][2][]const u8{
        .{ "echo $(a) `a`", "(list (cmd \"echo\" (w (cs (list (cmd \"a\")))) (w (bt (list (cmd \"a\"))))))" },
        .{ "echo $(a $(b))", "(list (cmd \"echo\" (w (cs (list (cmd \"a\" (w (cs (list (cmd \"b\"))))))))))" },
        .{ "echo `a \\`b\\``", "(list (cmd \"echo\" (w (bt (list (cmd \"a\" (w (bt (list (cmd \"b\"))))))))))" },
        .{ "echo `a \\\\ b`", "(list (cmd \"echo\" (w (bt (list (cmd \"a\" (w (q \" \") \"b\")))))))" },
        .{ "echo \"a $(b) `c` ${d}\"", "(list (cmd \"echo\" (w (dq \"a \" (cs (list (cmd \"b\"))) \" \" (bt (list (cmd \"c\"))) \" \" (v d)))))" },
        .{ "echo \"a $(echo \")\")\"", "(list (cmd \"echo\" (w (dq \"a \" (cs (list (cmd \"echo\" (w (dq \")\")))))))))" },
        .{ "echo $(echo a; echo b)", "(list (cmd \"echo\" (w (cs (list (cmd \"echo\" \"a\") (cmd \"echo\" \"b\"))))))" },
        .{ "echo $(\na\nb\n)", "(list (cmd \"echo\" (w (cs (list (cmd \"a\") (cmd \"b\"))))))" },
        .{ "echo $(case x in x) echo hi;; esac)", "(list (cmd \"echo\" (w (cs (list (case \"x\" ((\"x\") (list (cmd \"echo\" \"hi\")))))))))" },
        .{ "echo $(a # c ) \n)", "(list (cmd \"echo\" (w (cs (list (cmd \"a\"))))))" },
        .{ "echo <(a) >(b) <(a | b)", "(list (cmd \"echo\" (w (psi (list (cmd \"a\")))) (w (pso (list (cmd \"b\")))) (w (psi (list (pipe (cmd \"a\") | (cmd \"b\")))))))" },
        .{ "diff <(a) <(b)", "(list (cmd \"diff\" (w (psi (list (cmd \"a\")))) (w (psi (list (cmd \"b\"))))))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump brace tilde and quoting" {
    const cases = [_][2][]const u8{
        .{ "echo {a,b,c}", "(list (cmd \"echo\" (w (brace \"a\" \"b\" \"c\"))))" },
        .{ "echo {1..5} {a..e} {1..10..2} {a..z..3} {01..10} {-3..3}", "(list (cmd \"echo\" (w (seq \"1\" \"5\")) (w (seqc \"a\" \"e\")) (w (seq \"1\" \"10\" \"2\")) (w (seqc \"a\" \"z\" \"3\")) (w (seq \"01\" \"10\")) (w (seq \"-3\" \"3\"))))" },
        .{ "echo a{b,c}d {x,y}{1,2}", "(list (cmd \"echo\" (w \"a\" (brace \"b\" \"c\") \"d\") (w (brace \"x\" \"y\") (brace \"1\" \"2\"))))" },
        .{ "echo {a,{b,c},d}", "(list (cmd \"echo\" (w (brace \"a\" (w (brace \"b\" \"c\")) \"d\"))))" },
        .{ "echo {a,b}$x", "(list (cmd \"echo\" (w (brace \"a\" \"b\") (v x))))" },
        .{ "echo {a}", "(list (cmd \"echo\" \"{a}\"))" },
        .{ "echo {a,b", "(list (cmd \"echo\" \"{a,b\"))" },
        .{ "echo {}", "(list (cmd \"echo\" \"{}\"))" },
        .{ "echo { a }", "(list (cmd \"echo\" \"{\" \"a\" \"}\"))" },
        .{ "echo {,a}", "(list (cmd \"echo\" (w (brace (w) \"a\"))))" },
        .{ "echo ~ ~/x ~root ~root/x ~+ ~-", "(list (cmd \"echo\" (w (tilde \"\")) (w (tilde \"\") \"/x\") (w (tilde \"root\")) (w (tilde \"root\") \"/x\") (w (tilde \"+\")) (w (tilde \"-\"))))" },
        .{ "echo a~b \"~\" '~' \\~", "(list (cmd \"echo\" \"a~b\" (w (dq \"~\")) (w (q \"~\")) (w (q \"~\"))))" },
        .{ "echo a\\ b 'c d' \"e f\" a\\'b", "(list (cmd \"echo\" (w \"a\" (q \" \") \"b\") (w (q \"c d\")) (w (dq \"e f\")) (w \"a\" (q \"'\") \"b\")))" },
        .{ "echo \"a\\\"b\" \"a\\$b\" \"a\\\\b\" \"a\\nb\" \"a\\`b\"", "(list (cmd \"echo\" (w (dq \"a\\\"b\")) (w (dq \"a$b\")) (w (dq \"a\\\\b\")) (w (dq \"a\\\\nb\")) (w (dq \"a`b\"))))" },
        .{ "echo 'a\\b'", "(list (cmd \"echo\" (w (q \"a\\\\b\"))))" },
        .{ "echo $'a\\tb\\n' $'\\x41\\101é' $'it\\'s'", "(list (cmd \"echo\" (w (ansi \"a\\tb\\n\")) (w (ansi \"AAé\")) (w (ansi \"it's\"))))" },
        .{ "echo $\"hello\"", "(list (cmd \"echo\" (w (dq \"hello\"))))" },
        .{ "echo a\"b\"c'd'e", "(list (cmd \"echo\" (w \"a\" (dq \"b\") \"c\" (q \"d\") \"e\")))" },
        .{ "echo \"a\nb\"", "(list (cmd \"echo\" (w (dq \"a\\nb\"))))" },
        .{ "echo a # comment", "(list (cmd \"echo\" \"a\"))" },
        .{ "# comment\necho a", "(list (cmd \"echo\" \"a\"))" },
        .{ "echo a#b", "(list (cmd \"echo\" \"a#b\"))" },
        .{ "echo a \\\nb", "(list (cmd \"echo\" \"a\" \"b\"))" },
        .{ "echo a\\\nb", "(list (cmd \"echo\" \"ab\"))" },
        .{ "echo \"a\\\nb\"", "(list (cmd \"echo\" (w (dq \"ab\"))))" },
        .{ "a;b;c", "(list (cmd \"a\") (cmd \"b\") (cmd \"c\"))" },
        .{ "a\nb\nc", "(list (cmd \"a\") (cmd \"b\") (cmd \"c\"))" },
        .{ "\n\na\n", "(list (cmd \"a\"))" },
        .{ "{ echo a; } | { cat; }", "(list (pipe (grp (list (cmd \"echo\" \"a\"))) | (grp (list (cmd \"cat\")))))" },
        .{ "( a ) | ( b )", "(list (pipe (sub (list (cmd \"a\"))) | (sub (list (cmd \"b\")))))" },
        .{ "while a; do b; done | c", "(list (pipe (while (list (cmd \"a\")) (list (cmd \"b\"))) | (cmd \"c\")))" },
        .{ "while a; do b; done > f", "(list (R (while (list (cmd \"a\")) (list (cmd \"b\"))) (r > \"f\")))" },
        .{ "for i in 1; do :; done 2>&1 | cat", "(list (pipe (R (for \"i\" (in \"1\") (list (cmd \":\"))) (r 2 >& \"1\")) | (cmd \"cat\")))" },
        .{ "if a; then b; fi > f 2>&1", "(list (R (if (list (cmd \"a\")) (list (cmd \"b\"))) (r > \"f\") (r 2 >& \"1\")))" },
        .{ "case x in a) b;; esac > f", "(list (R (case \"x\" ((\"a\") (list (cmd \"b\")))) (r > \"f\")))" },
        .{ "f() { :; }; f", "(list (fn \"f\" (grp (list (cmd \":\")))) (cmd \"f\"))" },
        .{ "echo }", "(list (cmd \"echo\" \"}\"))" },
        // error case skipped: 'echo { a; }'
        .{ "echo [[ ]]", "(list (cmd \"echo\" \"[[\" \"]]\"))" },
        .{ "echo ]]", "(list (cmd \"echo\" \"]]\"))" },
        .{ "echo !", "(list (cmd \"echo\" \"!\"))" },
        .{ "echo ! a", "(list (cmd \"echo\" \"!\" \"a\"))" },
        .{ "echo a!b", "(list (cmd \"echo\" \"a!b\"))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump arithmetic expansion" {
    const cases = [_][2][]const u8{
        .{ "echo $((1+2))", "(list (cmd \"echo\" (w (arith (+ 1 2)))))" },
        .{ "echo $((1 + 2 * 3 - 4 / 5 % 6))", "(list (cmd \"echo\" (w (arith (- (+ 1 (* 2 3)) (% (/ 4 5) 6))))))" },
        .{ "echo $((2 ** 3 ** 2))", "(list (cmd \"echo\" (w (arith (** 2 (** 3 2))))))" },
        .{ "echo $((-x)) $((+x)) $((!x)) $((~x)) $((- -x))", "(list (cmd \"echo\" (w (arith (neg x))) (w (arith (pos x))) (w (arith (! x))) (w (arith (~ x))) (w (arith (neg (neg x))))))" },
        .{ "echo $((x++)) $((x--)) $((++x)) $((--x))", "(list (cmd \"echo\" (w (arith (post++ x))) (w (arith (post-- x))) (w (arith (pre++ x))) (w (arith (pre-- x)))))" },
        .{ "echo $((a?b:c)) $((a?b?c:d:e)) $((a?b:c?d:e))", "(list (cmd \"echo\" (w (arith (? a b c))) (w (arith (? a (? b c d) e))) (w (arith (? a b (? c d e))))))" },
        .{ "echo $((a=1)) $((a+=1)) $((a-=1)) $((a*=1)) $((a/=1)) $((a%=1)) $((a<<=1)) $((a>>=1)) $((a&=1)) $((a^=1)) $((a|=1))", "(list (cmd \"echo\" (w (arith (= a 1))) (w (arith (+= a 1))) (w (arith (-= a 1))) (w (arith (*= a 1))) (w (arith (/= a 1))) (w (arith (%= a 1))) (w (arith (<<= a 1))) (w (arith (>>= a 1))) (w (arith (&= a 1))) (w (arith (^= a 1))) (w (arith (|= a 1)))))" },
        .{ "echo $((a,b)) $((a=1,b=2))", "(list (cmd \"echo\" (w (arith (, a b))) (w (arith (, (= a 1) (= b 2))))))" },
        .{ "echo $((a<b)) $((a<=b)) $((a>b)) $((a>=b)) $((a==b)) $((a!=b))", "(list (cmd \"echo\" (w (arith (< a b))) (w (arith (<= a b))) (w (arith (> a b))) (w (arith (>= a b))) (w (arith (== a b))) (w (arith (!= a b)))))" },
        .{ "echo $((a&&b||c)) $((a||b&&c)) $((a&b|c^d))", "(list (cmd \"echo\" (w (arith (|| (&& a b) c))) (w (arith (|| a (&& b c)))) (w (arith (| (& a b) (^ c d))))))" },
        .{ "echo $((a<<1)) $((a>>1)) $((a<<1+1))", "(list (cmd \"echo\" (w (arith (<< a 1))) (w (arith (>> a 1))) (w (arith (<< a (+ 1 1))))))" },
        .{ "echo $((0x1f)) $((017)) $((2#101)) $((64#a)) $((16#FF))", "(list (cmd \"echo\" (w (arith 31)) (w (arith 15)) (w (arith 5)) (w (arith 10)) (w (arith 255))))" },
        .{ "echo $((08)) $((1a))", "(list (cmd \"echo\" (w (arith (badnum \"08\"))) (w (arith (badnum \"1a\")))))" },
        .{ "echo $((a[1])) $((a[i+1]+1)) $((a[b[1]]))", "(list (cmd \"echo\" (w (arith (idx a 1))) (w (arith (+ (idx a (+ i 1)) 1))) (w (arith (idx a (idx b 1))))))" },
        .{ "echo $(( (1+2)*3 ))", "(list (cmd \"echo\" (w (arith (* (+ 1 2) 3)))))" },
        .{ "echo $(( $x + ${y} + $(z) ))", "(list (cmd \"echo\" (w (arith (+ (+ (exp (w (v x))) (exp (w (v y)))) (exp (w (cs (list (cmd \"z\"))))))))))" },
        .{ "echo $(( x$i ))", "(list (cmd \"echo\" (w (arith (exp (w \"x\" (v i)))))))" },
        .{ "echo $(( ))", "(list (cmd \"echo\" (w (arith 0))))" },
        .{ "echo $(())", "(list (cmd \"echo\" (w (arith 0))))" },
        .{ "echo $((1 +))", "(list (cmd \"echo\" (w (arith (invalid \"syntax error: operand expected (error token is \\\"\\\")\")))))" },
        .{ "echo $((1 2))", "(list (cmd \"echo\" (w (arith (invalid \"syntax error in expression (error token is \\\"2\\\")\")))))" },
        .{ "echo $((1 = 2))", "(list (cmd \"echo\" (w (arith (invalid \"attempted assignment to non-variable (error token is \\\"= 2\\\")\")))))" },
        .{ "echo $[1+2]", "(list (cmd \"echo\" (w (arith (+ 1 2)))))" },
        .{ "echo $((a)) $(( a ))", "(list (cmd \"echo\" (w (arith a)) (w (arith a))))" },
        .{ "echo \"$((1+2))\"", "(list (cmd \"echo\" (w (dq (arith (+ 1 2))))))" },
        .{ "x=$((1+2))", "(list (cmd (= x (w (arith (+ 1 2))))))" },
        .{ "(( a ))", "(list (arith-cmd a))" },
        .{ "((a))", "(list (arith-cmd a))" },
        .{ "((a)) && b", "(list (&& (arith-cmd a) (cmd \"b\")))" },
        .{ "(( ))", "(list (arith-cmd 0))" },
        .{ "((echo a); b)", "(list (sub (list (sub (list (cmd \"echo\" \"a\"))) (cmd \"b\"))))" },
        .{ "( (a) )", "(list (sub (list (sub (list (cmd \"a\"))))))" },
        .{ "(( a )) ; (( b ))", "(list (arith-cmd a) (arith-cmd b))" },
        .{ "echo $((echo a) | cat)", "(list (cmd \"echo\" (w (cs (list (pipe (sub (list (cmd \"echo\" \"a\"))) | (cmd \"cat\")))))))" },
        .{ "echo $( (a) )", "(list (cmd \"echo\" (w (cs (list (sub (list (cmd \"a\"))))))))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "dump extglob and misc" {
    const cases = [_][2][]const u8{
        .{ "echo *(a)", "(list (cmd \"echo\" \"*(a)\"))" },
        .{ "echo @(a|b) +(c) ?(d) !(e)", "(list (cmd \"echo\" \"@(a|b)\" \"+(c)\" \"?(d)\" \"!(e)\"))" },
        .{ "echo *.txt ?x [a-z]*", "(list (cmd \"echo\" \"*.txt\" \"?x\" \"[a-z]*\"))" },
        .{ "case x in @(a|b)) :;; esac", "(list (case \"x\" ((\"@(a|b)\") (list (cmd \":\")))))" },
        .{ "coproc a", "(list (coproc (cmd \"a\")))" },
        .{ "coproc NAME { a; }", "(list (coproc \"NAME\" (grp (list (cmd \"a\")))))" },
        .{ "coproc { a; }", "(list (coproc (grp (list (cmd \"a\")))))" },
        .{ "echo a || echo b &", "(list (& (|| (cmd \"echo\" \"a\") (cmd \"echo\" \"b\"))))" },
        .{ "a && { b; c; }", "(list (&& (cmd \"a\") (grp (list (cmd \"b\") (cmd \"c\")))))" },
        .{ "a || ( b )", "(list (|| (cmd \"a\") (sub (list (cmd \"b\")))))" },
        .{ "a &&\nb", "(list (&& (cmd \"a\") (cmd \"b\")))" },
        .{ "a ||\nb", "(list (|| (cmd \"a\") (cmd \"b\")))" },
        .{ "a |\nb", "(list (pipe (cmd \"a\") | (cmd \"b\")))" },
        .{ "a |&\nb", "(list (pipe (cmd \"a\") |& (cmd \"b\")))" },
        .{ "a;\nb", "(list (cmd \"a\") (cmd \"b\"))" },
        .{ "if a; then b; fi; if c; then d; fi", "(list (if (list (cmd \"a\")) (list (cmd \"b\"))) (if (list (cmd \"c\")) (list (cmd \"d\"))))" },
        .{ "echo $x$y${z}\"$w\"'$v'", "(list (cmd \"echo\" (w (v x) (v y) (v z) (dq (v w)) (q \"$v\"))))" },
        .{ "a=1; b=2; echo $a$b", "(list (cmd (= a \"1\")) (cmd (= b \"2\")) (cmd \"echo\" (w (v a) (v b))))" },
        .{ "FOO=bar baz", "(list (cmd (= FOO \"bar\") \"baz\"))" },
        .{ "FOO=bar BAR=baz cmd arg1 arg2 > out", "(list (cmd (= FOO \"bar\") (= BAR \"baz\") \"cmd\" \"arg1\" \"arg2\" (r > \"out\")))" },
        .{ "echo a b   c", "(list (cmd \"echo\" \"a\" \"b\" \"c\"))" },
        .{ "echo\ttab", "(list (cmd \"echo\" \"tab\"))" },
        .{ "echo \"a\" \"b\"", "(list (cmd \"echo\" (w (dq \"a\")) (w (dq \"b\"))))" },
        .{ "echo \"\"", "(list (cmd \"echo\" (w (dq))))" },
        .{ "echo '' \"\" a''b\n", "(list (cmd \"echo\" (w (q \"\")) (w (dq)) (w \"a\" (q \"\") \"b\")))" },
    };
    for (cases) |c| try expect_dump(c[0], c[1]);
}

test "syntax error messages" {
    const cases = [_][2][]const u8{
        .{ "if then", "zash: -c: line 1: syntax error near unexpected token `then'\nzash: -c: line 1: `if then'\n" },
        .{ "echo (", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `echo ('\n" },
        .{ "echo )", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `echo )'\n" },
        .{ "if true; then", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo \"abc", "zash: -c: line 1: unexpected EOF while looking for matching `\"'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo 'abc", "zash: -c: line 1: unexpected EOF while looking for matching `''\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo $(", "zash: -c: line 1: unexpected EOF while looking for matching `)'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo `ls", "zash: -c: line 1: unexpected EOF while looking for matching ``'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "a ||", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "&& a", "zash: -c: line 1: syntax error near unexpected token `&&'\nzash: -c: line 1: `&& a'\n" },
        .{ "a | | b", "zash: -c: line 1: syntax error near unexpected token `|'\nzash: -c: line 1: `a | | b'\n" },
        .{ "case x in a) ;;", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "for i in 1; echo", "zash: -c: line 1: syntax error near unexpected token `echo'\nzash: -c: line 1: `for i in 1; echo'\n" },
        .{ "fi", "zash: -c: line 1: syntax error near unexpected token `fi'\nzash: -c: line 1: `fi'\n" },
        .{ "done", "zash: -c: line 1: syntax error near unexpected token `done'\nzash: -c: line 1: `done'\n" },
        .{ "}", "zash: -c: line 1: syntax error near unexpected token `}'\nzash: -c: line 1: `}'\n" },
        .{ ";;", "zash: -c: line 1: syntax error near unexpected token `;;'\nzash: -c: line 1: `;;'\n" },
        .{ "echo a;; b", "zash: -c: line 1: syntax error near unexpected token `;;'\nzash: -c: line 1: `echo a;; b'\n" },
        .{ "echo ${", "zash: -c: line 1: unexpected EOF while looking for matching `}'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo ${a", "zash: -c: line 1: unexpected EOF while looking for matching `}'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "f()", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "function", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `function'\n" },
        .{ "while true; do", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "( echo", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "{ echo", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo >", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `echo >'\n" },
        .{ "echo <", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `echo <'\n" },
        .{ "echo a &&", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo $((1+", "zash: -c: line 1: unexpected EOF while looking for matching `)'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo ${a/b", "zash: -c: line 1: unexpected EOF while looking for matching `}'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "if; then a; fi", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `if; then a; fi'\n" },
        .{ "echo |", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "|", "zash: -c: line 1: syntax error near unexpected token `|'\nzash: -c: line 1: `|'\n" },
        .{ "echo a b ) c", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `echo a b ) c'\n" },
        .{ "do", "zash: -c: line 1: syntax error near unexpected token `do'\nzash: -c: line 1: `do'\n" },
        .{ "then a", "zash: -c: line 1: syntax error near unexpected token `then'\nzash: -c: line 1: `then a'\n" },
        .{ "esac", "zash: -c: line 1: syntax error near unexpected token `esac'\nzash: -c: line 1: `esac'\n" },
        .{ "case x in a) echo;; b echo ;; esac", "zash: -c: line 1: syntax error near unexpected token `echo'\nzash: -c: line 1: `case x in a) echo;; b echo ;; esac'\n" },
        .{ "for in", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "f() { :; } ; f ()", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "x=1 ( a )", "zash: -c: line 1: syntax error near unexpected token `('\nzash: -c: line 1: `x=1 ( a )'\n" },
        .{ "echo a <<<", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `echo a <<<'\n" },
        .{ "[[ a == ]]", "zash: -c: line 1: unexpected argument `]]' to conditional binary operator\nzash: -c: line 1: syntax error near `]]'\nzash: -c: line 1: `[[ a == ]]'\n" },
        .{ "[[ a", "zash: -c: line 1: unexpected token `newline', conditional binary operator expected\nzash: -c: line 1: syntax error near `a'\nzash: -c: line 1: `[[ a'\n" },
        .{ "[[ a b ]]", "zash: -c: line 1: conditional binary operator expected\nzash: -c: line 1: syntax error near `b'\nzash: -c: line 1: `[[ a b ]]'\n" },
        .{ "[[ -f ]]", "zash: -c: line 1: unexpected argument `]]' to conditional unary operator\nzash: -c: line 1: syntax error near `]]'\nzash: -c: line 1: `[[ -f ]]'\n" },
        .{ "[[ ( a ]]", "zash: -c: line 1: unexpected token `]]', expected `)'\nzash: -c: line 1: syntax error near `]]'\nzash: -c: line 1: `[[ ( a ]]'\n" },
        .{ "echo a\necho b\nfi", "zash: -c: line 3: syntax error near unexpected token `fi'\nzash: -c: line 3: `fi'\n" },
        .{ "echo a\n\n  done", "zash: -c: line 3: syntax error near unexpected token `done'\nzash: -c: line 3: `  done'\n" },
        .{ "if a; then b; done", "zash: -c: line 1: syntax error near unexpected token `done'\nzash: -c: line 1: `if a; then b; done'\n" },
        .{ "while a; do b; fi", "zash: -c: line 1: syntax error near unexpected token `fi'\nzash: -c: line 1: `while a; do b; fi'\n" },
        .{ "for i in a; do b; esac", "zash: -c: line 1: syntax error near unexpected token `esac'\nzash: -c: line 1: `for i in a; do b; esac'\n" },
        .{ "case x in a) b; fi", "zash: -c: line 1: syntax error near unexpected token `fi'\nzash: -c: line 1: `case x in a) b; fi'\n" },
        .{ "{ a; fi", "zash: -c: line 1: syntax error near unexpected token `fi'\nzash: -c: line 1: `{ a; fi'\n" },
        .{ "( a; }", "zash: -c: line 1: syntax error near unexpected token `}'\nzash: -c: line 1: `( a; }'\n" },
        .{ "{ a; )", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `{ a; )'\n" },
        .{ "if a; then b; else; fi", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `if a; then b; else; fi'\n" },
        .{ "if a; then b; elif; fi", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `if a; then b; elif; fi'\n" },
        .{ "if a; then b; elif c; fi", "zash: -c: line 1: syntax error near unexpected token `fi'\nzash: -c: line 1: `if a; then b; elif c; fi'\n" },
        .{ "a & & b", "zash: -c: line 1: syntax error near unexpected token `&'\nzash: -c: line 1: `a & & b'\n" },
        .{ "a ; ; b", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `a ; ; b'\n" },
        .{ "a && ; b", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `a && ; b'\n" },
        .{ "a ; && b", "zash: -c: line 1: syntax error near unexpected token `&&'\nzash: -c: line 1: `a ; && b'\n" },
        .{ "case x in a)) b;; esac", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `case x in a)) b;; esac'\n" },
        .{ "case x in a|) b;; esac", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `case x in a|) b;; esac'\n" },
        .{ "case x in |a) b;; esac", "zash: -c: line 1: syntax error near unexpected token `|'\nzash: -c: line 1: `case x in |a) b;; esac'\n" },
        .{ "for i in a b c do :; done", "zash: -c: line 1: syntax error near unexpected token `done'\nzash: -c: line 1: `for i in a b c do :; done'\n" },
        .{ "select x in; done", "zash: -c: line 1: syntax error near unexpected token `done'\nzash: -c: line 1: `select x in; done'\n" },
        .{ "echo > > f", "zash: -c: line 1: syntax error near unexpected token `>'\nzash: -c: line 1: `echo > > f'\n" },
        .{ "echo >&", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `echo >&'\n" },
        .{ "echo > ;", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `echo > ;'\n" },
        .{ "echo ((a))", "zash: -c: line 1: syntax error near unexpected token `('\nzash: -c: line 1: `echo ((a))'\n" },
        .{ "echo a (b)", "zash: -c: line 1: syntax error near unexpected token `('\nzash: -c: line 1: `echo a (b)'\n" },
        .{ "cmd 2>", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `cmd 2>'\n" },
        .{ "cat <<", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `cat <<'\n" },
        .{ "cat << ;", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `cat << ;'\n" },
        .{ "echo \"a\nb", "zash: -c: line 1: unexpected EOF while looking for matching `\"'\nzash: -c: line 3: syntax error: unexpected end of file\n" },
        .{ "echo 'a\nb", "zash: -c: line 1: unexpected EOF while looking for matching `''\nzash: -c: line 3: syntax error: unexpected end of file\n" },
        .{ "echo $(echo \"a)", "zash: -c: line 1: unexpected EOF while looking for matching `\"'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo ${a:-\"b}", "zash: -c: line 1: unexpected EOF while looking for matching `\"'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo \"${a\"", "zash: -c: line 1: unexpected EOF while looking for matching `}'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "if [ a ]; then\n  b\nelif", "zash: -c: line 4: syntax error: unexpected end of file\n" },
        .{ "x=(a b", "zash: -c: line 1: unexpected EOF while looking for matching `)'\nzash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "x=(a b)) c", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `x=(a b)) c'\n" },
        .{ "echo $(( 1 + (2 )", "zash: -c: line 1: syntax error near unexpected token `('\nzash: -c: line 1: `echo $(( 1 + (2 )'\n" },
        .{ "function f() ", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "function f", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "function f {", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "f() {", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "f() (", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "f() ( a", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "[[ a == b ]] ]]", "zash: -c: line 1: syntax error near unexpected token `]]'\nzash: -c: line 1: `[[ a == b ]] ]]'\n" },
        .{ "[[ a && ]]", "zash: -c: line 1: syntax error near `]]'\nzash: -c: line 1: `[[ a && ]]'\n" },
        .{ "[[ || a ]]", "zash: -c: line 1: unexpected token `||' in conditional command\nzash: -c: line 1: syntax error near `|'\nzash: -c: line 1: `[[ || a ]]'\n" },
        .{ "[[ a == b c ]]", "zash: -c: line 1: syntax error in conditional expression\nzash: -c: line 1: syntax error near `c'\nzash: -c: line 1: `[[ a == b c ]]'\n" },
        .{ "[[ ! ]]", "zash: -c: line 1: syntax error near `]]'\nzash: -c: line 1: `[[ ! ]]'\n" },
        .{ "[[ a ) ]]", "zash: -c: line 1: syntax error in conditional expression: unexpected token `)'\nzash: -c: line 1: syntax error near `)'\nzash: -c: line 1: `[[ a ) ]]'\n" },
        .{ "time ( ", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo a |& ", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "coproc", "zash: -c: line 1: syntax error near unexpected token `newline'\nzash: -c: line 1: `coproc'\n" },
        .{ "a;;", "zash: -c: line 1: syntax error near unexpected token `;;'\nzash: -c: line 1: `a;;'\n" },
        .{ "case x in a) echo a esac", "zash: -c: line 2: syntax error: unexpected end of file\n" },
        .{ "echo { a; }", "zash: -c: line 1: syntax error near unexpected token `}'\nzash: -c: line 1: `echo { a; }'\n" },
        .{ "[[ a ) ]]", "zash: -c: line 1: syntax error in conditional expression: unexpected token `)'\nzash: -c: line 1: syntax error near `)'\nzash: -c: line 1: `[[ a ) ]]'\n" },
        .{ "[[ || a ]]", "zash: -c: line 1: unexpected token `||' in conditional command\nzash: -c: line 1: syntax error near `|'\nzash: -c: line 1: `[[ || a ]]'\n" },
        .{ "echo a\n  fi\necho b", "zash: -c: line 2: syntax error near unexpected token `fi'\nzash: -c: line 2: `  fi'\n" },
        .{ "if a; then b; elif; fi", "zash: -c: line 1: syntax error near unexpected token `;'\nzash: -c: line 1: `if a; then b; elif; fi'\n" },
        .{ "a=(1 | 2)", "zash: -c: line 1: syntax error near unexpected token `|'\nzash: -c: line 1: `a=(1 | 2)'\n" },
        .{ "for ((i=0;i<3)); do :; done", "zash: -c: line 1: syntax error near unexpected token `('\nzash: -c: line 1: `for ((i=0;i<3)); do :; done'\n" },
        .{ "f() { echo; } )", "zash: -c: line 1: syntax error near unexpected token `)'\nzash: -c: line 1: `f() { echo; } )'\n" },
    };
    for (cases) |c| try expect_error(c[0], c[1]);
}

fn parse_ok(arena: Allocator, src: []const u8) !ast.List {
    switch (parse(arena, src, .{})) {
        .ok => |l| return l,
        .err => return error.TestUnexpectedResult,
    }
}

fn parse_err(arena: Allocator, src: []const u8) !ParseError {
    switch (parse(arena, src, .{})) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| return e,
    }
}

test "line numbers on items and commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try parse_ok(arena.allocator(), "a\n\nb\nif c; then\n  d\nfi\n");
    try std.testing.expectEqual(@as(usize, 3), l.items.len);
    try std.testing.expectEqual(@as(u32, 1), l.items[0].line);
    try std.testing.expectEqual(@as(u32, 3), l.items[1].line);
    try std.testing.expectEqual(@as(u32, 4), l.items[2].line);
    const cmd = l.items[2].and_or.first.commands[0];
    try std.testing.expectEqual(@as(u32, 4), cmd.line);
    const inner = cmd.body.if_cmd.clauses[0].body.items[0];
    try std.testing.expectEqual(@as(u32, 5), inner.line);
}

test "word line numbers span multiline quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try parse_ok(arena.allocator(), "echo \"a\nb\" c\necho d");
    const words = l.items[0].and_or.first.commands[0].body.simple.words;
    try std.testing.expectEqual(@as(u32, 1), words[1].line);
    try std.testing.expectEqual(@as(u32, 2), words[2].line);
    try std.testing.expectEqual(@as(u32, 3), l.items[1].line);
}

test "error fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse_err(arena.allocator(), "echo a\n  fi\necho b");
    try std.testing.expectEqual(ParseError.Kind.unexpected_token, e.kind);
    try std.testing.expectEqual(@as(u32, 2), e.line);
    try std.testing.expectEqual(@as(u32, 3), e.col);
    try std.testing.expectEqualStrings("fi", e.text);
    try std.testing.expectEqualStrings("  fi", e.src_line);
    const e2 = try parse_err(arena.allocator(), "if true; then\n");
    try std.testing.expectEqual(ParseError.Kind.unexpected_eof, e2.kind);
    try std.testing.expectEqual(@as(u32, 2), e2.eof_line);
    const e3 = try parse_err(arena.allocator(), "echo \"abc\n\n");
    try std.testing.expectEqual(ParseError.Kind.eof_matching, e3.kind);
    try std.testing.expectEqual(@as(u32, 1), e3.line);
    try std.testing.expectEqual(@as(u32, 3), e3.eof_line);
}

test "pipeline flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try parse_ok(arena.allocator(), "! time -p a |& b | c");
    const p = l.items[0].and_or.first;
    try std.testing.expect(p.negate);
    try std.testing.expectEqual(ast.TimeMode.time_posix, p.time);
    try std.testing.expectEqual(@as(usize, 3), p.commands.len);
    try std.testing.expectEqual(@as(usize, 2), p.pipe_stderr.len);
    try std.testing.expect(p.pipe_stderr[0]);
    try std.testing.expect(!p.pipe_stderr[1]);
}

test "assignment structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try parse_ok(arena.allocator(), "a+=1 b[2]=x c=(p [3]=q) cmd");
    const s = l.items[0].and_or.first.commands[0].body.simple;
    try std.testing.expectEqual(@as(usize, 3), s.assigns.len);
    try std.testing.expect(s.assigns[0].append);
    try std.testing.expectEqualStrings("a", s.assigns[0].name);
    try std.testing.expect(s.assigns[1].index != null);
    try std.testing.expectEqual(@as(usize, 2), s.assigns[2].value.array.len);
    try std.testing.expect(s.assigns[2].value.array[1].key != null);
    try std.testing.expectEqual(@as(usize, 1), s.words.len);
}

test "heredoc structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try parse_ok(arena.allocator(), "cat <<-'END'\n\t$x\n\tEND\n");
    const r = l.items[0].and_or.first.commands[0].redirs[0];
    try std.testing.expectEqual(ast.RedirOp.heredoc_strip, r.op);
    const h = r.heredoc.?;
    try std.testing.expectEqualStrings("END", h.delimiter);
    try std.testing.expect(h.quoted);
    try std.testing.expect(h.strip_tabs);
    try std.testing.expectEqualStrings("$x\n", h.body.parts[0].quoted);
}

test "heredoc inside substitution accepts closing paren after delimiter" {
    try expect_dump("x=$(cat <<EOF\na\nEOF)\necho b", "(list (cmd (= x (w (cs (list (cmd \"cat\" (r << \"EOF\" u (w \"a\\n\")))))))) (cmd \"echo\" \"b\"))");
}

test "substitution syntax errors are deferred" {
    try expect_dump("echo $(a;}) `a >` <(fi)", "(list (cmd \"echo\" (w (bad \"$(a;})\")) (w (bad \"`a >`\")) (w (bad \"<(fi)\"))))");
}

test "unterminated substitution is fatal" {
    try expect_error("echo $(a;", "zash: -c: line 1: unexpected EOF while looking for matching `)'\nzash: -c: line 2: syntax error: unexpected end of file\n");
}

test "extglob can be disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (parse(arena.allocator(), "echo *(a)", .{ .extglob = false })) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| try std.testing.expectEqualStrings("(", e.text),
    }
    _ = try parse_ok(arena.allocator(), "echo *(a)");
}

test "parse_arith_text for runtime reparse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse_arith_text(arena.allocator(), " 1+2*x ");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try dump.dump_arith(&aw.writer, e);
    try std.testing.expectEqualStrings("(+ 1 (* 2 x))", aw.written());
    const bad = try parse_arith_text(arena.allocator(), "1 +");
    try std.testing.expect(bad.* == .invalid);
}

test "arith value parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse_arith_text(arena.allocator(), "0x7fffffffffffffff + 18446744073709551615 + 36#zz + 64#_");
    try std.testing.expect(e.* == .binary);
    const l = try parse_arith_text(arena.allocator(), "18446744073709551615");
    try std.testing.expectEqual(@as(i64, -1), l.num);
}

test "deep nesting is rejected without crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 5000;
    const open = try a.alloc(u8, n * 2);
    for (0..n) |i| @memcpy(open[i * 2 ..][0..2], "{ ");
    try std.testing.expectEqual(ParseError.Kind.nesting, (try parse_err(a, open)).kind);
    const subs = try a.alloc(u8, n * 2);
    for (0..n) |i| @memcpy(subs[i * 2 ..][0..2], "$(");
    try std.testing.expectEqual(ParseError.Kind.nesting, (try parse_err(a, subs)).kind);
    const parens = try a.alloc(u8, n);
    @memset(parens, '(');
    try std.testing.expectEqual(ParseError.Kind.nesting, (try parse_err(a, parens)).kind);
}

test "long pipelines and lists parse iteratively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    for (0..20000) |_| try buf.appendSlice(a, "a | ");
    try buf.appendSlice(a, "b && c || d; ");
    for (0..20000) |_| try buf.appendSlice(a, "x && ");
    try buf.appendSlice(a, "y");
    const l = try parse_ok(a, buf.items);
    try std.testing.expectEqual(@as(usize, 2), l.items.len);
    try std.testing.expectEqual(@as(usize, 20001), l.items[0].and_or.first.commands.len);
    try std.testing.expectEqual(@as(usize, 20000), l.items[1].and_or.rest.len);
}

test "loops accept brace bodies" {
    try expect_dump("for i in a b; { echo $i; }", "(list (for \"i\" (in \"a\" \"b\") (list (cmd \"echo\" (w (v i))))))");
    try expect_dump("for ((;;)) { :; }", "(list (for-arith _ _ _ (list (cmd \":\"))))");
    try expect_dump("select x in a; { :; }", "(list (select \"x\" (in \"a\") (list (cmd \":\"))))");
}

test "arithmetic for header errors" {
    try expect_error("for ((i=0;i<3)); do :; done", "zash: -c: line 1: syntax error: arithmetic expression required\nzash: -c: line 1: syntax error: `((i=0;i<3))'\n");
    try expect_error("for ((i=0;i<3;i++;)); do :; done", "zash: -c: line 1: syntax error: `;' unexpected\nzash: -c: line 1: syntax error: `((i=0;i<3;i++;))'\n");
}

const fuzz_seeds = [_][]const u8{
    "echo a b | cat && ls || true; x=1 y=(1 2) cmd > f 2>&1 &",
    "if a; then b; elif c; then d; else e; fi",
    "for ((i=0;i<3;i++)); do echo $i; done; for i in a b; do :; done",
    "case x in a|b) echo ${x:-y}${x//a/b};; *) $((1+2*3));; esac",
    "cat <<EOF\nhello $x `date` $(cmd)\nEOF\necho after",
    "f() { [[ a == b && ( -f c || d =~ ^e+$ ) ]]; (( x++ )); }",
    "echo {a,b{1..3}} ~root/x <(a) >(b) $'a\\n' \"$(a \"b\")\" ${!x[@]:1:2}",
    "a=$(b `c`) d[1]+=e; while read l; do echo \"$l\"; done < <(x) | y",
};

test "fuzz mutations do not crash" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const alphabet = "abc $()`'\"\\{}[]<>|&;#!*?~=,.:-+/%^\n\t012";
    var buf: [256]u8 = undefined;
    var iter: usize = 0;
    while (iter < 20000) : (iter += 1) {
        const seed = fuzz_seeds[rnd.uintLessThan(usize, fuzz_seeds.len)];
        const n = @min(seed.len, buf.len);
        @memcpy(buf[0..n], seed[0..n]);
        var len = n;
        const muts = rnd.uintLessThan(usize, 6);
        var m: usize = 0;
        while (m < muts) : (m += 1) {
            switch (rnd.uintLessThan(usize, 3)) {
                0 => if (len > 0) {
                    buf[rnd.uintLessThan(usize, len)] = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                },
                1 => if (len > 0) {
                    const at = rnd.uintLessThan(usize, len);
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < buf.len) {
                    const at = rnd.uintLessThan(usize, len + 1);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
            }
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        switch (parse(arena.allocator(), buf[0..len], .{})) {
            .ok => |l| _ = try dump.dump_alloc(arena.allocator(), l),
            .err => |e| {
                var ebuf: [1024]u8 = undefined;
                var w = std.Io.Writer.fixed(&ebuf);
                e.write(&w, "zash") catch {};
            },
        }
    }
}

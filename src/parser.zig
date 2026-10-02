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
        if (time != .none and self.at_cmd_end()) return .{ .commands = &.{}, .negate = negate, .time = time };
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
        try self.expect_kw(.kw_do);
        const body = try self.parse_list(true);
        try self.expect_kw(.kw_done);
        const fi = ast.ForIn{ .name = name, .words = words, .body = body };
        return .{ .body = if (is_select) .{ .select = fi } else .{ .for_in = fi } };
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
                    stop = lx.extent(pos, ';', ';') orelse {
                        lx.pos = pos;
                        return self.unexpected();
                    };
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
        try self.expect_kw(.kw_do);
        const body = try self.parse_list(true);
        try self.expect_kw(.kw_done);
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
                else => {},
            }
            try self.case_clauses.append(self.alloc(), .{ .patterns = patterns, .body = body, .term = term });
            if (self.is_kw(.kw_esac)) break;
            if (self.tok.tag == .eof) return self.unexpected();
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

test "smoke" {
    try expect_dump("echo hi", "(list (cmd \"echo\" \"hi\"))");
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

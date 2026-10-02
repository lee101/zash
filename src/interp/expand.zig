const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const pattern = @import("pattern.zig");
const glob = @import("glob.zig");
const arith = @import("arith.zig");
const strutil = @import("strutil.zig");
const exec = @import("exec.zig");
const unparse = @import("unparse.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Allocator = std.mem.Allocator;

pub const ESC: u8 = 1;

pub const Mode = enum { fields, string, pattern, pattern_trace };

const Val = struct {
    set: bool = false,
    s: []const u8 = "",
    list: ?[]const []const u8 = null,
    star: bool = false,
    positional: bool = false,
    array_name: []const u8 = "",
    is_assoc: bool = false,
};

const B = struct {
    sh: *Shell,
    a: Allocator,
    mode: Mode,
    out: *std.ArrayList([]const u8),
    cur: std.ArrayList(u8) = .empty,
    have: bool = false,
    ifs: []const u8,
    glob_on: bool,
    at_empty: bool = false,
    split_lit: bool = false,

    fn add_raw(self: *B, text: []const u8) Err!void {
        if (text.len == 0) return;
        if (self.mode == .string or std.mem.findScalar(u8, text, ESC) == null) {
            try self.cur.appendSlice(self.a, text);
        } else {
            for (text) |c| {
                if (c == ESC) try self.cur.append(self.a, ESC);
                try self.cur.append(self.a, c);
            }
        }
        self.have = true;
    }

    fn add_quoted(self: *B, text: []const u8) Err!void {
        self.have = true;
        if (text.len == 0) return;
        if (self.mode == .string) return self.cur.appendSlice(self.a, text);
        if (self.mode == .pattern_trace) {
            for (text) |c| {
                try self.cur.append(self.a, ESC);
                try self.cur.append(self.a, c);
            }
            return;
        }
        for (text) |c| {
            switch (c) {
                '*', '?', '[', ']', '\\', '(', ')', '|', '!', '+', '@', '-', '^', ESC, '{', '}' => try self.cur.append(self.a, ESC),
                else => {},
            }
            try self.cur.append(self.a, c);
        }
    }

    fn is_ifs(self: *B, c: u8) bool {
        return std.mem.findScalar(u8, self.ifs, c) != null;
    }

    fn is_ifs_ws(self: *B, c: u8) bool {
        return (c == ' ' or c == '\t' or c == '\n') and self.is_ifs(c);
    }

    fn end_field(self: *B, force: bool) Err!void {
        if (self.mode != .fields) return;
        if (self.have or self.cur.items.len > 0 or force) {
            try self.push_field(self.cur.items);
            self.cur.clearRetainingCapacity();
            self.have = false;
        }
    }

    fn add_split(self: *B, text: []const u8) Err!void {
        if (text.len == 0) return;
        if (self.mode != .fields) return self.add_raw(text);
        if (self.ifs.len == 0) return self.add_raw(text);
        var i: usize = 0;
        const n = text.len;
        while (i < n) {
            const c = text[i];
            if (!self.is_ifs(c)) {
                var j = i;
                while (j < n and !self.is_ifs(text[j])) j += 1;
                try self.add_raw(text[i..j]);
                i = j;
                continue;
            }
            if (self.is_ifs_ws(c)) {
                var j = i;
                while (j < n and self.is_ifs_ws(text[j])) j += 1;
                if (j < n and self.is_ifs(text[j])) {
                    try self.end_field(true);
                    j += 1;
                    while (j < n and self.is_ifs_ws(text[j])) j += 1;
                    i = j;
                    continue;
                }
                try self.end_field(false);
                i = j;
                continue;
            }
            try self.end_field(true);
            i += 1;
            while (i < n and self.is_ifs_ws(text[i])) i += 1;
        }
    }

    fn add_result(self: *B, text: []const u8, quoted: bool) Err!void {
        if (quoted) return self.add_quoted(text);
        return self.add_split(text);
    }

    fn push_field(self: *B, text: []const u8) Err!void {
        const a = self.a;
        if (self.glob_on and has_unescaped_meta(text, true)) {
            const pat = try to_pattern(a, text);
            var matches: std.ArrayList([]const u8) = .empty;
            try glob.expand(self.sh, pat, &matches);
            if (matches.items.len > 0) {
                try self.out.appendSlice(a, matches.items);
                return;
            }
            if (self.sh.shopt(.failglob)) {
                self.sh.msg("no match: {s}", .{try dequote(a, text)});
                self.sh.status = 1;
                return error.Abort;
            }
            if (self.sh.shopt(.nullglob)) return;
        }
        try self.out.append(a, try dequote(a, text));
    }
};

fn has_unescaped_meta(text: []const u8, extglob: bool) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ESC => i += 1,
            '*', '?' => return true,
            '[' => {
                if (std.mem.findScalarPos(u8, text, i + 1, ']') != null) return true;
            },
            '+', '@', '!' => if (extglob and i + 1 < text.len and text[i + 1] == '(') return true,
            else => {},
        }
    }
    return false;
}

fn to_pattern(a: Allocator, text: []const u8) Err![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ESC and i + 1 < text.len) {
            i += 1;
            try out.append(a, '\\');
        }
        try out.append(a, text[i]);
    }
    return out.items;
}

fn dequote(a: Allocator, text: []const u8) Err![]u8 {
    if (std.mem.findScalar(u8, text, ESC) == null) return a.dupe(u8, text);
    var out = try a.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ESC and i + 1 < text.len) i += 1;
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

fn new_builder(sh: *Shell, mode: Mode, out: *std.ArrayList([]const u8)) B {
    return .{
        .sh = sh,
        .a = sh.sa,
        .mode = mode,
        .out = out,
        .ifs = sh.ifs(),
        .glob_on = mode == .fields and !sh.opt(.noglob),
    };
}

fn finish_field(b: *B) Err!void {
    if (b.mode == .fields) return b.end_field(false);
}

fn brace_expand(sh: *Shell, w: ast.Word, out: *std.ArrayList(ast.Word), depth: u32) Err!void {
    const a = sh.sa;
    var idx: ?usize = null;
    for (w.parts, 0..) |p, i| {
        switch (p) {
            .brace_list, .brace_seq => {
                idx = i;
                break;
            },
            else => {},
        }
    }
    const i = idx orelse {
        try out.append(a, w);
        return;
    };
    if (depth > 32) {
        try out.append(a, w);
        return;
    }
    const prefix = w.parts[0..i];
    const suffix = w.parts[i + 1 ..];
    switch (w.parts[i]) {
        .brace_list => |alts| {
            for (alts) |alt| {
                const np = try std.mem.concat(a, ast.Part, &.{ prefix, alt.parts, suffix });
                try brace_expand(sh, .{ .parts = np, .line = w.line }, out, depth + 1);
            }
        },
        .brace_seq => |seq| {
            var items: std.ArrayList([]const u8) = .empty;
            try gen_seq(sh, seq, &items);
            if (items.items.len == 0) {
                const np = try std.mem.concat(a, ast.Part, &.{ prefix, &[_]ast.Part{.{ .lit = "" }}, suffix });
                try out.append(a, .{ .parts = np, .line = w.line });
                return;
            }
            for (items.items) |it| {
                const np = try std.mem.concat(a, ast.Part, &.{ prefix, &[_]ast.Part{.{ .lit = it }}, suffix });
                try brace_expand(sh, .{ .parts = np, .line = w.line }, out, depth + 1);
            }
        },
        else => unreachable,
    }
}

fn parse_seq_int(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn gen_seq(sh: *Shell, seq: ast.BraceSeq, out: *std.ArrayList([]const u8)) Err!void {
    const a = sh.sa;
    var step: i64 = 1;
    if (seq.step) |st| step = parse_seq_int(st) orelse 1;
    if (step == 0) step = 1;
    if (step < 0) step = -step;
    if (seq.chars) {
        const f = seq.from[0];
        const t = seq.to[0];
        var c: i64 = f;
        const inc: i64 = if (f <= t) step else -step;
        while ((inc > 0 and c <= t) or (inc < 0 and c >= t)) : (c += inc) {
            const s = try a.alloc(u8, 1);
            s[0] = @intCast(c);
            try out.append(a, s);
            if (out.items.len > 1_000_000) break;
        }
        return;
    }
    const f = parse_seq_int(seq.from) orelse return;
    const t = parse_seq_int(seq.to) orelse return;
    var width: usize = 0;
    const zf = seq.from.len > 1 and (seq.from[0] == '0' or (seq.from[0] == '-' and seq.from.len > 2 and seq.from[1] == '0'));
    const zt = seq.to.len > 1 and (seq.to[0] == '0' or (seq.to[0] == '-' and seq.to.len > 2 and seq.to[1] == '0'));
    if (zf or zt) width = @max(seq.from.len, seq.to.len);
    var c = f;
    const inc: i64 = if (f <= t) step else -step;
    while ((inc > 0 and c <= t) or (inc < 0 and c >= t)) : (c += inc) {
        if (width > 0) {
            const neg = c < 0;
            const digits = try std.fmt.allocPrint(a, "{d}", .{if (neg) -c else c});
            const total = if (neg) width - 1 else width;
            var buf: std.ArrayList(u8) = .empty;
            if (neg) try buf.append(a, '-');
            if (digits.len < total) try buf.appendNTimes(a, '0', total - digits.len);
            try buf.appendSlice(a, digits);
            try out.append(a, buf.items);
        } else try out.append(a, try std.fmt.allocPrint(a, "{d}", .{c}));
        if (out.items.len > 1_000_000) break;
    }
}

pub fn word_fields(sh: *Shell, w: ast.Word, out: *std.ArrayList([]const u8)) Err!void {
    if (w.parts.len == 1) {
        switch (w.parts[0]) {
            .lit => |t| {
                if (!sh.opt(.noglob) and has_unescaped_meta(t, true)) {} else {
                    try out.append(sh.sa, t);
                    return;
                }
            },
            .quoted => |t| {
                try out.append(sh.sa, t);
                return;
            },
            else => {},
        }
    }
    var has_brace = false;
    if (sh.opt(.braceexpand)) {
        for (w.parts) |p| switch (p) {
            .brace_list, .brace_seq => has_brace = true,
            else => {},
        };
    }
    if (!has_brace) return word_fields_one(sh, w, out);
    var words: std.ArrayList(ast.Word) = .empty;
    try brace_expand(sh, w, &words, 0);
    for (words.items) |bw| try word_fields_one(sh, bw, out);
}

fn word_fields_one(sh: *Shell, w: ast.Word, out: *std.ArrayList([]const u8)) Err!void {
    var b = new_builder(sh, .fields, out);
    try parts(&b, w.parts, false);
    try finish_field(&b);
}

pub fn words_fields(sh: *Shell, words: []const ast.Word, out: *std.ArrayList([]const u8)) Err!void {
    for (words) |w| try word_fields(sh, w, out);
}

pub fn word_string(sh: *Shell, w: ast.Word) Err![]const u8 {
    if (w.parts.len == 0) return "";
    if (w.parts.len == 1) {
        switch (w.parts[0]) {
            .lit => |t| return t,
            .quoted => |t| return t,
            else => {},
        }
    }
    var dummy: std.ArrayList([]const u8) = .empty;
    var b = new_builder(sh, .string, &dummy);
    try parts(&b, w.parts, true);
    return b.cur.items;
}

pub fn word_string_unquoted(sh: *Shell, w: ast.Word) Err![]const u8 {
    var dummy: std.ArrayList([]const u8) = .empty;
    var b = new_builder(sh, .string, &dummy);
    try parts(&b, w.parts, false);
    return b.cur.items;
}

pub fn word_pattern(sh: *Shell, w: ast.Word) Err![]const u8 {
    var dummy: std.ArrayList([]const u8) = .empty;
    var b = new_builder(sh, .pattern, &dummy);
    try parts(&b, w.parts, false);
    return to_pattern(sh.sa, b.cur.items);
}

pub fn word_pattern_trace(sh: *Shell, w: ast.Word) Err![]const u8 {
    var dummy: std.ArrayList([]const u8) = .empty;
    var b = new_builder(sh, .pattern_trace, &dummy);
    try parts(&b, w.parts, false);
    return to_pattern(sh.sa, b.cur.items);
}

pub fn subscript_text(sh: *Shell, raw: []const u8) Err![]const u8 {
    if (std.mem.findAny(u8, raw, "$\"'`\\") == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '$' and i + 1 < raw.len and (std.ascii.isAlphabetic(raw[i + 1]) or raw[i + 1] == '_')) {
            var j = i + 1;
            while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) j += 1;
            try out.appendSlice(sh.sa, sh.get_or_empty(raw[i + 1 .. j]));
            i = j - 1;
        } else if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
            const close = std.mem.findScalarPos(u8, raw, i, '}') orelse raw.len;
            try out.appendSlice(sh.sa, sh.get_or_empty(raw[i + 2 .. close]));
            i = close;
        } else if (c == '"' or c == '\'') {
            continue;
        } else if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            try out.append(sh.sa, raw[i]);
        } else try out.append(sh.sa, c);
    }
    return out.items;
}

fn parts(b: *B, ps: []const ast.Part, quoted: bool) Err!void {
    for (ps) |p| try part(b, p, quoted);
}

fn part(b: *B, p: ast.Part, quoted: bool) Err!void {
    const sh = b.sh;
    switch (p) {
        .lit => |t| {
            if (quoted) return b.add_quoted(t);
            if (b.split_lit) return b.add_split(t);
            return b.add_raw(t);
        },
        .quoted => |t| return b.add_quoted(t),
        .ansi_c => |t| return b.add_quoted(t),
        .dquote => |inner| {
            const save_empty = b.at_empty;
            b.at_empty = false;
            try parts(b, inner, true);
            if (!(b.at_empty and inner.len == 1)) b.have = true;
            b.at_empty = save_empty;
        },
        .variable => |name| return variable(b, name, quoted),
        .param => |pe| return param(b, pe, quoted),
        .cmd_subst => |cs| {
            const text = try exec.cmd_subst(sh, cs);
            return b.add_result(text, quoted);
        },
        .arith => |node| {
            const v = arith.eval_node(sh, node, .expansion, "") catch |e| switch (e) {
                error.ArithError => {
                    sh.status = 1;
                    return error.Abort;
                },
                else => return e,
            };
            const text = try sh.tmp_fmt("{d}", .{v});
            return b.add_result(text, quoted);
        },
        .proc_subst => |ps| {
            const path = try exec.proc_subst(sh, ps);
            return b.add_quoted(path);
        },
        .tilde => |t| {
            if (try tilde(sh, t)) |r| return b.add_quoted(r);
            try b.add_raw("~");
            return b.add_raw(t);
        },
        .brace_list, .brace_seq => return,
        .array_init => return,
        .bad_subst => |t| {
            sh.msg("{s}: bad substitution", .{t});
            sh.status = 1;
            return error.Abort;
        },
    }
}

fn tilde(sh: *Shell, t: []const u8) Err!?[]const u8 {
    if (t.len == 0) {
        if (sh.get_scalar("HOME")) |h| return h;
        const pw = sys.getpwuid(sys.getuid()) orelse return null;
        return std.mem.span(pw.dir);
    }
    if (std.mem.eql(u8, t, "+")) return sh.get_scalar("PWD");
    if (std.mem.eql(u8, t, "-")) return sh.get_scalar("OLDPWD");
    if (t[0] == '+' or t[0] == '-' or std.ascii.isDigit(t[0])) {
        const digits = if (t[0] == '+' or t[0] == '-') t[1..] else t;
        if (digits.len > 0) {
            if (std.fmt.parseInt(usize, digits, 10)) |n| {
                const total = sh.dir_stack.items.len + 1;
                var idx: usize = n;
                if (t[0] == '-') {
                    if (n >= total) return null;
                    idx = total - 1 - n;
                }
                if (idx == 0) return sh.get_scalar("PWD");
                if (idx - 1 < sh.dir_stack.items.len) return sh.dir_stack.items[idx - 1];
                return null;
            } else |_| {}
        }
    }
    var buf: [256]u8 = undefined;
    const z = sys.cstr(&buf, t) orelse return null;
    const pw = sys.getpwnam(z) orelse return null;
    return std.mem.span(pw.dir);
}

pub fn tilde_expand_text(sh: *Shell, t: []const u8) Err!?[]const u8 {
    return tilde(sh, t);
}

fn is_special_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len == 1) return switch (name[0]) {
        '@', '*', '#', '?', '-', '$', '!', '_' => true,
        '0'...'9' => true,
        else => false,
    };
    return std.ascii.isDigit(name[0]);
}

fn positional_list(sh: *Shell) []const []const u8 {
    return @ptrCast(sh.pos.items);
}

fn flags_string(sh: *Shell) Err![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const map = [_]struct { o: shell.Opt, c: u8 }{
        .{ .o = .errexit, .c = 'e' },
        .{ .o = .noglob, .c = 'f' },
        .{ .o = .hashall, .c = 'h' },
        .{ .o = .keyword, .c = 'k' },
        .{ .o = .monitor, .c = 'm' },
        .{ .o = .noexec, .c = 'n' },
        .{ .o = .nounset, .c = 'u' },
        .{ .o = .verbose, .c = 'v' },
        .{ .o = .xtrace, .c = 'x' },
        .{ .o = .braceexpand, .c = 'B' },
        .{ .o = .noclobber, .c = 'C' },
        .{ .o = .errtrace, .c = 'E' },
        .{ .o = .histexpand, .c = 'H' },
        .{ .o = .physical, .c = 'P' },
        .{ .o = .functrace, .c = 'T' },
        .{ .o = .privileged, .c = 'p' },
        .{ .o = .onecmd, .c = 't' },
        .{ .o = .allexport, .c = 'a' },
        .{ .o = .notify, .c = 'b' },
    };
    const order = "himBHs";
    _ = order;
    for ([_]u8{ 'a', 'b', 'e', 'f', 'h', 'k', 'm', 'n', 'p', 't', 'u', 'v', 'x', 'B', 'C', 'E', 'H', 'P', 'T' }) |c| {
        for (map) |m| {
            if (m.c == c and sh.opt(m.o)) {
                if (c == 'h' or c == 'B') continue;
                try out.append(sh.sa, c);
            }
        }
        if (c == 'f' or c == 'e') {}
    }
    var final: std.ArrayList(u8) = .empty;
    if (sh.opt(.hashall)) try final.append(sh.sa, 'h');
    for (out.items) |c| try final.append(sh.sa, c);
    if (sh.opt(.braceexpand)) try final.append(sh.sa, 'B');
    if (sh.interactive) try final.append(sh.sa, 'i');
    if (sh.dash_c) try final.append(sh.sa, 'c');
    return final.items;
}

fn special_value(sh: *Shell, name: []const u8) Err!Val {
    switch (name[0]) {
        '#' => return .{ .set = true, .s = try sh.tmp_fmt("{d}", .{sh.pos.items.len}) },
        '?' => return .{ .set = true, .s = try sh.tmp_fmt("{d}", .{sh.status}) },
        '-' => return .{ .set = true, .s = try flags_string(sh) },
        '$' => return .{ .set = true, .s = try sh.tmp_fmt("{d}", .{sh.pid}) },
        '!' => {
            if (sh.last_bg == 0) return .{};
            return .{ .set = true, .s = try sh.tmp_fmt("{d}", .{sh.last_bg}) };
        },
        '_' => return .{ .set = true, .s = sh.last_arg },
        '0'...'9' => {
            const n = std.fmt.parseInt(usize, name, 10) catch return .{};
            if (n == 0) return .{ .set = true, .s = sh.script_name };
            if (n - 1 < sh.pos.items.len) return .{ .set = true, .s = sh.pos.items[n - 1] };
            return .{};
        },
        else => return .{},
    }
}

fn virtual_array(sh: *Shell, name: []const u8) Err!?[]const []const u8 {
    const a = sh.sa;
    if (std.mem.eql(u8, name, "FUNCNAME")) {
        if (sh.frames.items.len == 0) return null;
        var l: std.ArrayList([]const u8) = .empty;
        var i = sh.frames.items.len;
        while (i > 0) {
            i -= 1;
            try l.append(a, sh.frames.items[i].func.name);
        }
        try l.append(a, "main");
        return l.items;
    }
    if (std.mem.eql(u8, name, "BASH_SOURCE")) {
        var l: std.ArrayList([]const u8) = .empty;
        var i = sh.frames.items.len;
        while (i > 0) {
            i -= 1;
            try l.append(a, sh.frames.items[i].func.file);
        }
        try l.append(a, sh.script_name);
        return l.items;
    }
    if (std.mem.eql(u8, name, "BASH_LINENO")) {
        var l: std.ArrayList([]const u8) = .empty;
        var i = sh.frames.items.len;
        while (i > 0) {
            i -= 1;
            try l.append(a, try sh.tmp_fmt("{d}", .{sh.frames.items[i].call_line}));
        }
        try l.append(a, "0");
        return l.items;
    }
    if (std.mem.eql(u8, name, "PIPESTATUS")) {
        var l: std.ArrayList([]const u8) = .empty;
        for (sh.pipestatus[0..sh.pipestatus_len]) |s| try l.append(a, try sh.tmp_fmt("{d}", .{s}));
        return l.items;
    }
    if (std.mem.eql(u8, name, "DIRSTACK")) {
        var l: std.ArrayList([]const u8) = .empty;
        try l.append(a, sh.get_or_empty("PWD"));
        for (sh.dir_stack.items) |d| try l.append(a, d);
        return l.items;
    }
    return null;
}

fn array_values(sh: *Shell, v: *shell.Var) Err![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    switch (v.value) {
        .none => {},
        .str => |s| try l.append(sh.sa, s),
        .indexed => |*ix| for (ix.items.items) |e| try l.append(sh.sa, e.val),
        .assoc => |*m| {
            const ord = try m.ordered(sh.gpa);
            const vals = m.map.values();
            for (ord) |i| try l.append(sh.sa, vals[i]);
        },
    }
    return l.items;
}

fn array_keys(sh: *Shell, v: *shell.Var) Err![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    switch (v.value) {
        .none => {},
        .str => try l.append(sh.sa, "0"),
        .indexed => |*ix| for (ix.items.items) |e| try l.append(sh.sa, try sh.tmp_fmt("{d}", .{e.idx})),
        .assoc => |*m| {
            const ord = try m.ordered(sh.gpa);
            const ks = m.map.keys();
            for (ord) |i| try l.append(sh.sa, ks[i]);
        },
    }
    return l.items;
}

pub fn index_value(sh: *Shell, w: ast.Word) Err!i64 {
    const text = try word_string(sh, w);
    return arith.eval_string(sh, text);
}

pub fn lookup_base(sh: *Shell, name: []const u8, sub: ?ast.Subscript) Err!Val {
    if (sub == null) {
        if (is_special_name(name)) {
            if (name.len == 1 and (name[0] == '@' or name[0] == '*')) {
                return .{ .set = sh.pos.items.len > 0, .list = positional_list(sh), .star = name[0] == '*', .positional = true };
            }
            return special_value(sh, name);
        }
        if (std.mem.eql(u8, name, "BASH_SUBSHELL")) return .{ .set = true, .s = try sh.tmp_fmt("{d}", .{sh.subshell_level}) };
        if (std.mem.eql(u8, name, "BASH_COMMAND")) {
            const c = sh.cur_cmd orelse return .{ .set = true, .s = "" };
            return .{ .set = true, .s = try unparse.command_source(sh, c) };
        }
        if (try virtual_array(sh, name)) |l| {
            if (l.len == 0) return .{};
            return .{ .set = true, .s = l[0] };
        }
        const v = sh.find(name) orelse return .{};
        if (v.special != .none or v.value != .none) {
            const s = sh.scalar_of(v) orelse return .{};
            return .{ .set = true, .s = s };
        }
        return .{};
    }
    const s = sub.?;
    if (try virtual_array(sh, name)) |l| {
        switch (s) {
            .at, .star => return .{ .set = l.len > 0, .list = l, .star = s == .star, .array_name = name },
            .index => |w| {
                const idx = try index_value(sh, w);
                if (idx >= 0 and @as(usize, @intCast(idx)) < l.len) return .{ .set = true, .s = l[@intCast(idx)] };
                return .{};
            },
        }
    }
    const v = sh.find(name);
    switch (s) {
        .at, .star => {
            const vv = v orelse return .{ .list = &.{}, .star = s == .star, .array_name = name };
            const vals = try array_values(sh, vv);
            return .{ .set = vals.len > 0, .list = vals, .star = s == .star, .array_name = name, .is_assoc = vv.value == .assoc };
        },
        .index => |w| {
            const vv = v orelse {
                if (std.mem.eql(u8, name, "BASH_REMATCH")) return .{};
                _ = try index_value(sh, w);
                return .{};
            };
            switch (vv.value) {
                .assoc => |*m| {
                    const key = try word_string(sh, w);
                    const e = m.get(key) orelse return .{};
                    return .{ .set = true, .s = e, .array_name = name, .is_assoc = true };
                },
                .indexed => |*ix| {
                    var idx = try index_value(sh, w);
                    if (idx < 0) {
                        idx += ix.max_index() + 1;
                        if (idx < 0) {
                            sh.msg("{s}[{d}]: bad array subscript", .{ name, idx - ix.max_index() - 1 });
                            return .{};
                        }
                    }
                    const e = ix.get(idx) orelse return .{};
                    return .{ .set = true, .s = e, .array_name = name };
                },
                .str => |str| {
                    const idx = try index_value(sh, w);
                    if (idx == 0) return .{ .set = true, .s = str };
                    return .{};
                },
                .none => {
                    _ = try index_value(sh, w);
                    return .{};
                },
            }
        },
    }
}

fn variable(b: *B, name: []const u8, quoted: bool) Err!void {
    const sh = b.sh;
    if (!is_special_name(name)) {
        if (sh.vars.get(name)) |v| {
            if (v.special == .none and !v.flags.nameref) {
                switch (v.value) {
                    .str => |s| return b.add_result(s, quoted),
                    .indexed => |*ix| {
                        if (ix.get(0)) |s| return b.add_result(s, quoted);
                        return unbound_check(sh, name, false);
                    },
                    else => {},
                }
            }
        }
    }
    const pe: ast.ParamExp = .{ .name = name };
    return param(b, &pe, quoted);
}

fn unbound_check(sh: *Shell, name: []const u8, is_set: bool) Err!void {
    return unbound_check_sub(sh, name, null, is_set);
}

fn unbound_check_sub(sh: *Shell, name: []const u8, sub: ?ast.Subscript, is_set: bool) Err!void {
    if (is_set or !sh.opt(.nounset)) return;
    if (name.len == 1 and (name[0] == '@' or name[0] == '*')) return;
    if (sub) |s| {
        switch (s) {
            .index => |w| {
                const src = try unparse.word_source(sh, w);
                sh.msg("{s}[{s}]: unbound variable", .{ name, src });
                sh.status = if (sh.dash_c) 127 else 1;
                sh.fatal_expand = true;
                return error.Exit;
            },
            else => {},
        }
    }
    if (is_special_name(name) and name[0] != '_') {
        sh.msg("${s}: unbound variable", .{name});
        sh.status = if (sh.dash_c) 127 else 1;
        sh.fatal_expand = true;
        return error.Exit;
    }
    sh.msg("{s}: unbound variable", .{name});
    sh.status = if (sh.dash_c) 127 else 1;
    sh.fatal_expand = true;
    return error.Exit;
}

fn join_list(b: *B, l: []const []const u8, sep: []const u8) Err![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (l, 0..) |s, i| {
        if (i > 0) try out.appendSlice(b.a, sep);
        try out.appendSlice(b.a, s);
    }
    return out.items;
}

fn ifs_first(b: *B) []const u8 {
    const v = b.sh.vars.get("IFS");
    if (v == null or v.?.value == .none) return " ";
    if (b.ifs.len == 0) return "";
    return b.ifs[0..1];
}

fn emit_list(b: *B, l: []const []const u8, star: bool, quoted: bool) Err!void {
    if (b.mode != .fields) {
        const sep: []const u8 = if (star) ifs_first(b) else " ";
        const joined = try join_list(b, l, sep);
        return b.add_quoted(joined);
    }
    if (quoted) {
        if (star) {
            const joined = try join_list(b, l, ifs_first(b));
            return b.add_quoted(joined);
        }
        if (l.len == 0) {
            b.at_empty = true;
            return;
        }
        for (l, 0..) |s, i| {
            if (i > 0) try b.end_field(true);
            try b.add_quoted(s);
        }
        return;
    }
    for (l, 0..) |s, i| {
        if (i > 0) try b.end_field(false);
        try b.add_split(s);
    }
}

fn emit_val(b: *B, v: Val, quoted: bool) Err!void {
    if (v.list) |l| return emit_list(b, l, v.star, quoted);
    if (!v.set) return;
    return b.add_result(v.s, quoted);
}

fn cond_word_string(b: *B, cw: ast.CondWord, quoted: bool) Err!Val {
    _ = cw;
    _ = quoted;
    _ = b;
    return .{};
}

fn expand_operand(b: *B, w: ast.Word, quoted: bool) Err!void {
    const save = b.split_lit;
    if (!quoted and b.mode == .fields) b.split_lit = true;
    defer b.split_lit = save;
    try parts(b, w.parts, quoted);
}

fn operand_string(sh: *Shell, w: ast.Word, quoted: bool) Err![]const u8 {
    _ = quoted;
    return word_string(sh, w);
}

fn param(b: *B, pe: *const ast.ParamExp, quoted: bool) Err!void {
    const sh = b.sh;
    var name = pe.name;
    var sub = pe.subscript;
    if (pe.indirect) {
        if (pe.op == .prefix_names) {
            const pre = name;
            var names: std.ArrayList([]const u8) = .empty;
            var it = sh.vars.map.iterator();
            while (it.next()) |e| {
                if (std.mem.startsWith(u8, e.key_ptr.*, pre) and e.value_ptr.*.is_set_or_declared()) try names.append(sh.sa, e.key_ptr.*);
            }
            std.mem.sort([]const u8, names.items, {}, lessStr);
            return emit_list(b, names.items, pe.op.prefix_names == .star, quoted);
        }
        if (sub) |s| switch (s) {
            .at, .star => {
                if (try virtual_array(sh, name)) |_| {
                    const bv = try lookup_base(sh, name, sub);
                    var keys: std.ArrayList([]const u8) = .empty;
                    for (bv.list.?, 0..) |_, i| try keys.append(sh.sa, try sh.tmp_fmt("{d}", .{i}));
                    return emit_list(b, keys.items, s == .star, quoted);
                }
                const vv = sh.find(name);
                const keys: []const []const u8 = if (vv) |x| try array_keys(sh, x) else &.{};
                return emit_list(b, keys, s == .star, quoted);
            },
            .index => {},
        };
        const base = try lookup_base(sh, name, sub);
        const target = if (base.set) base.s else "";
        if (target.len == 0) {
            if (!base.set) try unbound_check(sh, name, false);
            if (pe.op != .none and (pe.op == .use_default or pe.op == .assign_default)) {} else return;
        }
        const lb = std.mem.findScalar(u8, target, '[');
        if (lb != null and target[target.len - 1] == ']') {
            name = target[0..lb.?];
            const inner = target[lb.? + 1 .. target.len - 1];
            if (std.mem.eql(u8, inner, "@")) {
                sub = .at;
            } else if (std.mem.eql(u8, inner, "*")) {
                sub = .star;
            } else {
                sub = .{ .index = .{ .parts = &[_]ast.Part{.{ .lit = inner }} } };
            }
        } else {
            name = target;
            sub = null;
            if (!Shell.is_valid_name(name) and !is_special_name(name)) {
                sh.msg("{s}: invalid variable name", .{name});
                sh.status = 1;
                return error.Abort;
            }
        }
    }
    var base = try lookup_base(sh, name, sub);

    if (pe.length) {
        if (sub != null and sub.? != .index and sh.opt(.nounset) and !is_special_name(name)) {
            const vv = sh.find(name);
            if (vv == null or !(vv.?.value == .indexed or vv.?.value == .assoc)) {
                sh.msg("{s}: unbound variable", .{name});
                sh.status = 1;
                return error.Abort;
            }
        }
        if (base.list != null and sub != null) {
            return b.add_result(try sh.tmp_fmt("{d}", .{base.list.?.len}), quoted);
        }
        if (base.list != null) return b.add_result(try sh.tmp_fmt("{d}", .{base.list.?.len}), quoted);
        if (!base.set) {
            try unbound_check(sh, name, false);
            return b.add_result("0", quoted);
        }
        return b.add_result(try sh.tmp_fmt("{d}", .{strutil.char_len(sh.utf8, base.s)}), quoted);
    }

    switch (pe.op) {
        .none => {
            if (!base.set and base.list == null) try unbound_check_sub(sh, name, sub, false);
            return emit_val(b, base, quoted);
        },
        .use_default, .assign_default, .error_unset, .use_alt => {
            const cw = switch (pe.op) {
                .use_default => |c| c,
                .assign_default => |c| c,
                .error_unset => |c| c,
                .use_alt => |c| c,
                else => unreachable,
            };
            var unset = !base.set;
            if (base.list != null) unset = base.list.?.len == 0 or (cw.colon and base.list.?.len == 0);
            if (!unset and cw.colon and base.list == null and base.s.len == 0) unset = true;
            if (!unset and cw.colon and base.list != null and base.star) {
                const j = try join_list(b, base.list.?, "");
                if (j.len == 0) unset = true;
            }
            switch (pe.op) {
                .use_default => {
                    if (unset) return expand_operand(b, cw.word, quoted);
                    return emit_val(b, base, quoted);
                },
                .use_alt => {
                    if (unset) return;
                    return expand_operand(b, cw.word, quoted);
                },
                .assign_default => {
                    if (!unset) return emit_val(b, base, quoted);
                    if (is_special_name(name) or (sub != null and sub.? != .index)) {
                        sh.msg("${s}: cannot assign in this way", .{name});
                        sh.status = 1;
                        return error.Abort;
                    }
                    const val = try word_string(sh, cw.word);
                    if (sub) |s| {
                        switch (s) {
                            .index => |iw| {
                                const v = sh.find(name) orelse try sh.new_var(name);
                                if (v.value == .assoc) {
                                    try sh.assign_assoc(v, try word_string(sh, iw), val, false);
                                } else try sh.assign_indexed(v, try index_value(sh, iw), val, false);
                            },
                            else => {},
                        }
                    } else try sh.assign_scalar(name, val, false);
                    return b.add_result(val, quoted);
                },
                .error_unset => {
                    if (!unset) return emit_val(b, base, quoted);
                    const m = try word_string(sh, cw.word);
                    if (cw.word.parts.len == 0) {
                        sh.msg("{s}: {s}", .{ name, if (cw.colon) "parameter null or not set" else "parameter not set" });
                    } else sh.msg("{s}: {s}", .{ name, m });
                    sh.status = if (sh.dash_c) 127 else 1;
                    sh.fatal_expand = true;
                    return error.Exit;
                },
                else => unreachable,
            }
        },
        else => {},
    }

    if (!base.set and base.list == null) {
        try unbound_check_sub(sh, name, sub, false);
    }
    if (base.list == null and !base.set) {
        switch (pe.op) {
            .substring, .trim, .replace, .case_mod, .transform => {
                if (pe.op == .transform) {}
                return;
            },
            else => return,
        }
    }

    switch (pe.op) {
        .trim => |t| {
            const pat = try word_pattern(sh, t.pattern);
            if (base.list) |l| {
                const out = try sh.sa.alloc([]const u8, l.len);
                for (l, 0..) |s, i| out[i] = try trim(sh, s, pat, t.kind);
                base.list = out;
                return emit_val(b, base, quoted);
            }
            base.s = try trim(sh, base.s, pat, t.kind);
            return emit_val(b, base, quoted);
        },
        .replace => |r| {
            const pat = try word_pattern(sh, r.pattern);
            const rep: []const u8 = if (r.replacement) |rw| try word_string(sh, rw) else "";
            if (base.list) |l| {
                const out = try sh.sa.alloc([]const u8, l.len);
                for (l, 0..) |s, i| out[i] = try replace(sh, s, pat, rep, r.kind);
                base.list = out;
                return emit_val(b, base, quoted);
            }
            base.s = try replace(sh, base.s, pat, rep, r.kind);
            return emit_val(b, base, quoted);
        },
        .case_mod => |cm| {
            const pat: ?[]const u8 = if (cm.pattern) |pw| try word_pattern(sh, pw) else null;
            if (base.list) |l| {
                const out = try sh.sa.alloc([]const u8, l.len);
                for (l, 0..) |s, i| out[i] = try case_mod(sh, s, cm.upper, cm.all, pat);
                base.list = out;
                return emit_val(b, base, quoted);
            }
            base.s = try case_mod(sh, base.s, cm.upper, cm.all, pat);
            return emit_val(b, base, quoted);
        },
        .substring => |ss| {
            const off = arith.eval_node(sh, ss.offset, .expansion, "") catch |e| switch (e) {
                error.ArithError => {
                    sh.status = 1;
                    return error.Abort;
                },
                else => return e,
            };
            var len: ?i64 = null;
            if (ss.length) |le| {
                len = arith.eval_node(sh, le, .expansion, "") catch |e| switch (e) {
                    error.ArithError => {
                        sh.status = 1;
                        return error.Abort;
                    },
                    else => return e,
                };
            }
            if (base.list) |l| {
                const sl = try sublist(sh, base, l, off, len);
                base.list = sl;
                return emit_val(b, base, quoted);
            }
            const r = substring(sh, base.s, off, len) orelse {
                sh.msg("{s}: substring expression < 0", .{if (len) |ln| try sh.tmp_fmt("{d}", .{ln}) else ""});
                sh.status = 1;
                return error.Abort;
            };
            base.s = r;
            return emit_val(b, base, quoted);
        },
        .transform => |c| {
            if (base.list) |l| {
                const out = try sh.sa.alloc([]const u8, l.len);
                for (l, 0..) |s, i| out[i] = try transform(sh, c, s, name, sub != null);
                base.list = out;
                return emit_val(b, base, quoted);
            }
            base.s = try transform(sh, c, base.s, name, sub != null);
            return emit_val(b, base, quoted);
        },
        else => return emit_val(b, base, quoted),
    }
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn match_opts(sh: *Shell) pattern.Opts {
    return .{ .extglob = sh.shopt(.extglob) or true, .nocase = sh.shopt(.nocasematch) };
}

fn trim(sh: *Shell, s: []const u8, pat: []const u8, kind: ast.TrimKind) Err![]const u8 {
    const a = sh.sa;
    const o = match_opts(sh);
    if (!pattern.has_meta(pat, true)) {
        const lit = try pattern.unescape(a, pat);
        switch (kind) {
            .prefix, .prefix_longest => return if (std.mem.startsWith(u8, s, lit)) s[lit.len..] else s,
            .suffix, .suffix_longest => return if (std.mem.endsWith(u8, s, lit)) s[0 .. s.len - lit.len] else s,
        }
    }
    switch (kind) {
        .prefix => {
            var k: usize = 0;
            while (k <= s.len) : (k += 1) {
                if (pattern.match(a, pat, s[0..k], o)) return s[k..];
            }
        },
        .prefix_longest => {
            var k: usize = s.len + 1;
            while (k > 0) {
                k -= 1;
                if (pattern.match(a, pat, s[0..k], o)) return s[k..];
            }
        },
        .suffix => {
            var k: usize = s.len + 1;
            while (k > 0) {
                k -= 1;
                if (pattern.match(a, pat, s[k..], o)) return s[0..k];
            }
        },
        .suffix_longest => {
            var k: usize = 0;
            while (k <= s.len) : (k += 1) {
                if (pattern.match(a, pat, s[k..], o)) return s[0..k];
            }
        },
    }
    return s;
}

fn replace(sh: *Shell, s: []const u8, pat: []const u8, rep: []const u8, kind: ast.ReplaceKind) Err![]const u8 {
    const a = sh.sa;
    if (pat.len == 0) {
        switch (kind) {
            .prefix => return std.mem.concat(a, u8, &.{ rep, s }),
            .suffix => return std.mem.concat(a, u8, &.{ s, rep }),
            else => return s,
        }
    }
    const o = match_opts(sh);
    var out: std.ArrayList(u8) = .empty;
    const literal = !pattern.has_meta(pat, true);
    const lit = if (literal) try pattern.unescape(a, pat) else pat;
    switch (kind) {
        .prefix => {
            if (literal) {
                if (std.mem.startsWith(u8, s, lit)) {
                    try out.appendSlice(a, rep);
                    try out.appendSlice(a, s[lit.len..]);
                    return out.items;
                }
                return s;
            }
            var k: usize = s.len + 1;
            while (k > 0) {
                k -= 1;
                if (pattern.match(a, pat, s[0..k], o)) {
                    try out.appendSlice(a, rep);
                    try out.appendSlice(a, s[k..]);
                    return out.items;
                }
            }
            return s;
        },
        .suffix => {
            if (literal) {
                if (std.mem.endsWith(u8, s, lit)) {
                    try out.appendSlice(a, s[0 .. s.len - lit.len]);
                    try out.appendSlice(a, rep);
                    return out.items;
                }
                return s;
            }
            var k: usize = 0;
            while (k <= s.len) : (k += 1) {
                if (pattern.match(a, pat, s[k..], o)) {
                    try out.appendSlice(a, s[0..k]);
                    try out.appendSlice(a, rep);
                    return out.items;
                }
            }
            return s;
        },
        .first, .all => {
            var i: usize = 0;
            var replaced = false;
            while (i <= s.len) {
                if (replaced and kind == .first) break;
                var mlen: ?usize = null;
                if (literal) {
                    if (std.mem.startsWith(u8, s[i..], lit)) mlen = lit.len;
                } else {
                    var k: usize = s.len + 1;
                    while (k > i) {
                        k -= 1;
                        if (pattern.match(a, pat, s[i..k], o)) {
                            mlen = k - i;
                            break;
                        }
                    }
                }
                if (mlen) |m| {
                    if (m == 0) {
                        if (i < s.len) {
                            try out.append(a, s[i]);
                        }
                        i += 1;
                        continue;
                    }
                    try out.appendSlice(a, rep);
                    i += m;
                    replaced = true;
                } else {
                    if (i < s.len) try out.append(a, s[i]);
                    i += 1;
                }
            }
            if (i <= s.len) try out.appendSlice(a, s[@min(i, s.len)..]);
            if (!replaced) return s;
            return out.items;
        },
    }
}

fn case_mod(sh: *Shell, s: []const u8, upper: bool, all: bool, pat: ?[]const u8) Err![]const u8 {
    const a = sh.sa;
    var out = try a.dupe(u8, s);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        var ok = true;
        if (pat) |p| {
            var one = [_]u8{c};
            ok = pattern.match(a, p, &one, match_opts(sh));
        }
        if (ok) out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        if (!all) break;
    }
    return out;
}

fn substring(sh: *Shell, s: []const u8, off_in: i64, len_in: ?i64) ?[]const u8 {
    const n: i64 = @intCast(strutil.char_len(sh.utf8, s));
    var off = off_in;
    if (off < 0) {
        off += n;
        if (off < 0) return "";
    }
    if (off > n) return "";
    var end: i64 = n;
    if (len_in) |l| {
        if (l < 0) {
            end = n + l;
            if (end < off) return null;
        } else end = @min(n, off + l);
    }
    const bs = strutil.char_offset(sh.utf8, s, @intCast(off));
    const be = strutil.char_offset(sh.utf8, s, @intCast(end));
    return s[bs..be];
}

fn sublist(sh: *Shell, base: Val, l: []const []const u8, off_in: i64, len_in: ?i64) Err![]const []const u8 {
    const a = sh.sa;
    if (base.positional) {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(a, sh.script_name);
        try all.appendSlice(a, l);
        const total: i64 = @intCast(all.items.len);
        var off = off_in;
        if (off < 0) off += total;
        if (off < 0) return &.{};
        if (off > total) return &.{};
        var end = total;
        if (len_in) |ln| {
            if (ln < 0) {
                end = total + ln;
                if (end < off) {
                    sh.msg("{d}: substring expression < 0", .{ln});
                    sh.status = 1;
                    return error.Abort;
                }
            } else end = @min(total, off + ln);
        }
        return all.items[@intCast(off)..@intCast(end)];
    }
    if (base.array_name.len > 0 and !base.is_assoc) {
        if (sh.find(base.array_name)) |v| {
            if (v.value == .indexed) {
                const ix = &v.value.indexed;
                var off = off_in;
                if (off < 0) {
                    off += ix.max_index() + 1;
                    if (off < 0) return &.{};
                }
                var out: std.ArrayList([]const u8) = .empty;
                var count: i64 = 0;
                for (ix.items.items) |e| {
                    if (e.idx < off) continue;
                    if (len_in) |ln| {
                        if (ln >= 0 and count >= ln) break;
                    }
                    try out.append(a, e.val);
                    count += 1;
                }
                if (len_in) |ln| {
                    if (ln < 0) {
                        const keep = @as(i64, @intCast(out.items.len)) + ln;
                        if (keep < 0) return &.{};
                        out.items.len = @intCast(keep);
                    }
                }
                return out.items;
            }
        }
    }
    const total: i64 = @intCast(l.len);
    var off = off_in;
    if (off < 0) off += total;
    if (off < 0 or off > total) return &.{};
    var end = total;
    if (len_in) |ln| {
        if (ln < 0) {
            end = total + ln;
            if (end < off) return &.{};
        } else end = @min(total, off + ln);
    }
    return l[@intCast(off)..@intCast(end)];
}

fn transform(sh: *Shell, c: u8, s: []const u8, name: []const u8, has_sub: bool) Err![]const u8 {
    const a = sh.sa;
    var out: std.ArrayList(u8) = .empty;
    switch (c) {
        'Q' => try strutil.quote_for_at_q(a, &out, s),
        'E' => {
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == '\\' and i + 1 < s.len) {
                    const r = try strutil.ansi_escape(a, &out, s, i + 1, true);
                    i += 1 + r.consumed;
                } else {
                    try out.append(a, s[i]);
                    i += 1;
                }
            }
        },
        'U' => {
            for (s) |ch| try out.append(a, std.ascii.toUpper(ch));
        },
        'L' => {
            for (s) |ch| try out.append(a, std.ascii.toLower(ch));
        },
        'u' => {
            try out.appendSlice(a, s);
            if (out.items.len > 0) out.items[0] = std.ascii.toUpper(out.items[0]);
        },
        'P' => try out.appendSlice(a, s),
        'a' => {
            if (sh.find(name)) |v| {
                if (v.value == .indexed) try out.append(a, 'a');
                if (v.value == .assoc) try out.append(a, 'A');
                if (v.flags.integer) try out.append(a, 'i');
                if (v.flags.lower) try out.append(a, 'l');
                if (v.flags.nameref) try out.append(a, 'n');
                if (v.flags.readonly) try out.append(a, 'r');
                if (v.flags.trace) try out.append(a, 't');
                if (v.flags.upper) try out.append(a, 'u');
                if (v.flags.exported) try out.append(a, 'x');
            }
        },
        'A' => {
            if (sh.find(name)) |v| {
                var attrs: std.ArrayList(u8) = .empty;
                if (v.value == .indexed) try attrs.append(a, 'a');
                if (v.value == .assoc) try attrs.append(a, 'A');
                if (v.flags.integer) try attrs.append(a, 'i');
                if (v.flags.lower) try attrs.append(a, 'l');
                if (v.flags.nameref) try attrs.append(a, 'n');
                if (v.flags.readonly) try attrs.append(a, 'r');
                if (v.flags.upper) try attrs.append(a, 'u');
                if (v.flags.exported) try attrs.append(a, 'x');
                if (attrs.items.len > 0) {
                    try out.appendSlice(a, "declare -");
                    try out.appendSlice(a, attrs.items);
                    try out.append(a, ' ');
                }
                try out.appendSlice(a, name);
                if (!has_sub) {
                    try out.append(a, '=');
                    try strutil.single_quote(a, &out, s);
                }
            } else return "";
        },
        'K', 'k' => try strutil.quote_for_at_q(a, &out, s),
        else => try out.appendSlice(a, s),
    }
    return out.items;
}

pub fn heredoc_string(sh: *Shell, body: ast.Word) Err![]const u8 {
    var dummy: std.ArrayList([]const u8) = .empty;
    var b = new_builder(sh, .string, &dummy);
    try parts(&b, body.parts, true);
    return b.cur.items;
}

pub fn dollar_at_list(sh: *Shell) []const []const u8 {
    return positional_list(sh);
}

pub fn get_var_text(sh: *Shell, text: []const u8) Err!?[]const u8 {
    if (std.mem.findScalar(u8, text, '[')) |lb| {
        if (text[text.len - 1] == ']') {
            const name = text[0..lb];
            const sub = text[lb + 1 .. text.len - 1];
            const v = sh.find(name) orelse return null;
            switch (v.value) {
                .assoc => |*m| return m.get(sub),
                .indexed => |*ix| {
                    var idx = try sh.eval_int(sub);
                    if (idx < 0) idx += ix.max_index() + 1;
                    return ix.get(idx);
                },
                .str => |s| return if ((try sh.eval_int(sub)) == 0) s else null,
                .none => return null,
            }
        }
    }
    return sh.get_scalar(text);
}

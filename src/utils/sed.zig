const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const regex = @import("regex.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;
const Allocator = std.mem.Allocator;

const specs = [_]common.OptSpec{
    .{ .id = 'n', .short = 'n', .long = "quiet" },
    .{ .id = 'n', .long = "silent" },
    .{ .id = 'E', .short = 'E', .long = "regexp-extended" },
    .{ .id = 'E', .short = 'r' },
    .{ .id = 'e', .short = 'e', .long = "expression", .arg = .required },
};

const no_re: u32 = std.math.maxInt(u32);
const unset: usize = std.math.maxInt(usize);

const AddrKind = enum { line, last, re, step, zero, plus };

const Addr = struct { kind: AddrKind, n: u64 = 0, step: u64 = 0, re: u32 = no_re };

const Op = enum { block_open, block_close, label, p, P, d, D, n, N, g, G, h, H, x, s, y, q, Q, eq, a, i, c, b, t, T };

const Part = union(enum) { lit: []const u8, group: u8, upper, lower, upper1, lower1, end_case };

const Sub = struct {
    re: u32,
    parts: []const Part,
    global: bool,
    nth: u32,
    print: bool,
    groups: bool,
    cased: bool,
};

const Cmd = struct {
    op: Op,
    a1: ?Addr = null,
    a2: ?Addr = null,
    neg: bool = false,
    active: bool = false,
    end_line: u64 = 0,
    jump: u32 = 0,
    code: u8 = 0,
    text: []const u8 = "",
    label: []const u8 = "",
    sub: ?*const Sub = null,
    ytab: ?*const [256]u8 = null,
};

const PErr = error{ Bad, OutOfMemory };

const Program = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    cmds: []Cmd = &.{},
    res: std.ArrayList(*regex.Regex) = .empty,
    quiet: bool,
    ere: bool,
    utf8: bool,
    uses_case: bool = false,
    uses_t: bool = false,
    uses_nd: bool = false,
    stop_after: ?u64 = null,

    fn init(gpa: Allocator, quiet: bool, ere: bool, utf8: bool) Program {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .quiet = quiet, .ere = ere, .utf8 = utf8 };
    }

    fn deinit(self: *Program) void {
        for (self.res.items) |r| r.deinit();
        self.res.deinit(self.gpa);
        self.arena.deinit();
    }
};

fn isSpecialDelim(c: u8) bool {
    return std.mem.findScalar(u8, ".*[]^$+?(){}|", c) != null;
}

fn controlEscape(c: u8) ?u8 {
    return switch (c) {
        't' => '\t',
        'f' => 0x0c,
        'v' => 0x0b,
        'r' => '\r',
        'a' => 0x07,
        else => null,
    };
}

fn captureSafe(pat: []const u8, ere: bool) bool {
    var i: usize = 0;
    var prev_close = false;
    while (i < pat.len) {
        const c = pat[i];
        var close = false;
        if (c == '\\') {
            if (i + 1 >= pat.len) return false;
            const n = pat[i + 1];
            if (!ere) {
                if (n == '|' or n == '?' or n == '{') return false;
                if (prev_close and n == '+') return false;
                if (n == ')') close = true;
            }
            i += 2;
            prev_close = close;
            continue;
        }
        if (c == '[') {
            i += 1;
            if (i < pat.len and pat[i] == '^') i += 1;
            if (i < pat.len and pat[i] == ']') i += 1;
            while (i < pat.len and pat[i] != ']') {
                if (pat[i] == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '.' or pat[i + 1] == '=')) {
                    const d = pat[i + 1];
                    i += 2;
                    while (i + 1 < pat.len and !(pat[i] == d and pat[i + 1] == ']')) i += 1;
                    i += 2;
                    continue;
                }
                i += 1;
            }
            i += 1;
            prev_close = false;
            continue;
        }
        if (ere) {
            if (c == '|' or c == '?' or c == '{') return false;
            if (prev_close and (c == '*' or c == '+')) return false;
            if (c == ')') close = true;
        } else if (prev_close and c == '*') return false;
        i += 1;
        prev_close = close;
    }
    return true;
}

const Parser = struct {
    prog: *Program,
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    cmds: std.ArrayList(Cmd) = .empty,
    stack: std.ArrayList(u32) = .empty,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipBlank(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
    }

    fn skipSep(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) switch (self.src[self.pos]) {
            ' ', '\t', '\n', ';', '\r', 0x0b, 0x0c => {},
            else => return,
        };
    }

    fn number(self: *Parser) PErr!?u64 {
        const start = self.pos;
        var v: u64 = 0;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {
            const m = @mulWithOverflow(v, 10);
            const s = @addWithOverflow(m[0], self.src[self.pos] - '0');
            if (m[1] != 0 or s[1] != 0) return error.Bad;
            v = s[0];
        }
        return if (self.pos == start) null else v;
    }

    fn endOfCmd(self: *Parser) PErr!void {
        self.skipBlank();
        const c = self.peek() orelse return;
        switch (c) {
            '\n', ';' => self.pos += 1,
            '}', '#' => {},
            else => return error.Bad,
        }
    }

    fn scanRegex(self: *Parser, delim: u8) PErr![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return error.Bad;
            self.pos += 1;
            if (c == delim) break;
            if (c == '\n') return error.Bad;
            if (c != '\\') {
                try out.append(self.a, c);
                continue;
            }
            const n = self.peek() orelse return error.Bad;
            self.pos += 1;
            if (n == delim) {
                if (isSpecialDelim(delim)) return error.Bad;
                try out.append(self.a, delim);
            } else if (n == 'n') {
                try out.append(self.a, '\n');
            } else if (controlEscape(n)) |cc| {
                try out.append(self.a, cc);
            } else if (n == 'c' or n == 'd' or n == 'o' or n == 'x' or n == '\n') {
                return error.Bad;
            } else {
                try out.append(self.a, '\\');
                try out.append(self.a, n);
            }
        }
        return out.items;
    }

    fn compile(self: *Parser, pat: []const u8, icase: bool, need_groups: bool) PErr!u32 {
        const prog = self.prog;
        if (pat.len == 0) {
            if (icase or prog.res.items.len == 0) return error.Bad;
            return no_re;
        }
        if (need_groups and !captureSafe(pat, prog.ere)) return error.Bad;
        const re = regex.Regex.compile(prog.gpa, &.{pat}, .{
            .syntax = if (prog.ere) .ere else .bre,
            .icase = icase,
            .unicode = if (prog.utf8) .glibc else .none,
            .line_mode = false,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Bad,
        };
        errdefer re.deinit();
        if ((prog.utf8 and re.sensitive) or re.nfa.states.items.len > 20000) return error.Bad;
        try prog.res.append(prog.gpa, re);
        return @intCast(prog.res.items.len - 1);
    }

    fn addr(self: *Parser, second: bool) PErr!?Addr {
        const c = self.peek() orelse return null;
        if (std.ascii.isDigit(c)) {
            const n = (try self.number()).?;
            if (self.peek() == '~') {
                if (second) return error.Bad;
                self.pos += 1;
                const st = (try self.number()) orelse return error.Bad;
                return .{ .kind = .step, .n = n, .step = st };
            }
            return .{ .kind = .line, .n = n };
        }
        switch (c) {
            '$' => {
                self.pos += 1;
                return .{ .kind = .last };
            },
            '+' => {
                if (!second) return error.Bad;
                self.pos += 1;
                const n = (try self.number()) orelse return error.Bad;
                return .{ .kind = .plus, .n = n };
            },
            '/', '\\' => {
                self.pos += 1;
                var delim: u8 = '/';
                if (c == '\\') {
                    delim = self.peek() orelse return error.Bad;
                    if (delim == '\n' or delim == '\\') return error.Bad;
                    self.pos += 1;
                }
                const pat = try self.scanRegex(delim);
                var icase = false;
                while (self.peek()) |f| {
                    if (f == 'I') icase = true else if (f == 'M') return error.Bad else break;
                    self.pos += 1;
                }
                return .{ .kind = .re, .re = try self.compile(pat, icase, false) };
            },
            else => return null,
        }
    }

    fn readLabel(self: *Parser) PErr![]const u8 {
        self.skipBlank();
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (c == ';' or c == '\n' or c == ' ' or c == '\t' or c == '\r') break;
            if (c == '}') return error.Bad;
        }
        return self.src[start..self.pos];
    }

    fn readText(self: *Parser) PErr![]const u8 {
        self.skipBlank();
        const c = self.peek() orelse return error.Bad;
        if (c == '\\') {
            self.pos += 1;
            const n = self.peek() orelse return error.Bad;
            if (n == '\n') self.pos += 1;
        } else if (c == '\n') return error.Bad;
        var out: std.ArrayList(u8) = .empty;
        while (self.peek()) |ch| {
            self.pos += 1;
            if (ch == '\n') break;
            if (ch == '\\') {
                const n = self.peek() orelse break;
                self.pos += 1;
                if (n == '\n') {
                    try out.append(self.a, '\n');
                } else if (std.ascii.isAlphanumeric(n)) {
                    return error.Bad;
                } else try out.append(self.a, n);
                continue;
            }
            try out.append(self.a, ch);
        }
        try out.append(self.a, '\n');
        return out.items;
    }

    fn parseSub(self: *Parser) PErr!*const Sub {
        const delim = self.peek() orelse return error.Bad;
        if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '\n' or delim == ' ' or delim == '&') return error.Bad;
        self.pos += 1;
        const pat = try self.scanRegex(delim);
        var parts: std.ArrayList(Part) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        var max_group: u8 = 0;
        var cased = false;
        while (true) {
            const c = self.peek() orelse return error.Bad;
            self.pos += 1;
            if (c == delim) break;
            if (c == '\n') return error.Bad;
            var part: ?Part = null;
            if (c == '&') {
                part = .{ .group = 0 };
            } else if (c == '\\') {
                const n = self.peek() orelse return error.Bad;
                self.pos += 1;
                if (n == delim) {
                    try lit.append(self.a, n);
                } else if (std.ascii.isDigit(n)) {
                    part = .{ .group = n - '0' };
                    max_group = @max(max_group, n - '0');
                } else if (n == 'n' or n == '\n') {
                    try lit.append(self.a, '\n');
                } else if (controlEscape(n)) |cc| {
                    try lit.append(self.a, cc);
                } else switch (n) {
                    'U' => part = .upper,
                    'L' => part = .lower,
                    'u' => part = .upper1,
                    'l' => part = .lower1,
                    'E' => part = .end_case,
                    else => if (std.ascii.isAlphanumeric(n)) return error.Bad else try lit.append(self.a, n),
                }
                if (part) |pp| switch (pp) {
                    .upper, .lower, .upper1, .lower1, .end_case => cased = true,
                    else => {},
                };
            } else try lit.append(self.a, c);
            if (part) |pp| {
                if (lit.items.len > 0) {
                    try parts.append(self.a, .{ .lit = try self.a.dupe(u8, lit.items) });
                    lit.clearRetainingCapacity();
                }
                try parts.append(self.a, pp);
            }
        }
        if (lit.items.len > 0) try parts.append(self.a, .{ .lit = try self.a.dupe(u8, lit.items) });
        var global = false;
        var print = false;
        var icase = false;
        var nth: u32 = 0;
        while (self.peek()) |f| {
            if (f == 'g') {
                if (global) return error.Bad;
                global = true;
            } else if (f == 'p') {
                if (print) return error.Bad;
                print = true;
            } else if (f == 'i' or f == 'I') {
                icase = true;
            } else if (std.ascii.isDigit(f)) {
                if (nth != 0) return error.Bad;
                const n = (try self.number()).?;
                if (n == 0 or n > std.math.maxInt(u32)) return error.Bad;
                nth = @intCast(n);
                continue;
            } else if (f == 'w' or f == 'e' or f == 'm' or f == 'M') {
                return error.Bad;
            } else break;
            self.pos += 1;
        }
        try self.endOfCmd();
        const groups = max_group > 0;
        if (groups and pat.len == 0) return error.Bad;
        const ri = try self.compile(pat, icase, groups);
        if (groups and self.prog.res.items[ri].ngroups < max_group) return error.Bad;
        if (cased) {
            if (self.prog.utf8) return error.Bad;
            self.prog.uses_case = true;
        }
        const sub = try self.a.create(Sub);
        sub.* = .{ .re = ri, .parts = parts.items, .global = global, .nth = if (nth == 0) 1 else nth, .print = print, .groups = groups, .cased = cased };
        return sub;
    }

    fn yEnd(self: *Parser, delim: u8) PErr![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return error.Bad;
            self.pos += 1;
            if (c == delim) break;
            if (c == '\n' or c >= 0x80) return error.Bad;
            if (c != '\\') {
                try out.append(self.a, c);
                continue;
            }
            const n = self.peek() orelse return error.Bad;
            self.pos += 1;
            if (n == delim or n == '\\') {
                try out.append(self.a, n);
            } else if (n == 'n') {
                try out.append(self.a, '\n');
            } else return error.Bad;
        }
        return out.items;
    }

    fn parseY(self: *Parser) PErr!*const [256]u8 {
        const delim = self.peek() orelse return error.Bad;
        if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '\n') return error.Bad;
        self.pos += 1;
        const from = try self.yEnd(delim);
        const to = try self.yEnd(delim);
        if (from.len != to.len) return error.Bad;
        try self.endOfCmd();
        const tab = try self.a.create([256]u8);
        for (tab, 0..) |*b, i| b.* = @intCast(i);
        var i = from.len;
        while (i > 0) {
            i -= 1;
            tab[from[i]] = to[i];
        }
        return tab;
    }

    fn parse(self: *Parser) PErr!void {
        if (std.mem.startsWith(u8, self.src, "#n") and (self.src.len == 2 or self.src[2] == '\n')) return error.Bad;
        while (true) {
            self.skipSep();
            const c0 = self.peek() orelse break;
            if (c0 == '#') {
                while (self.peek()) |ch| {
                    if (ch == '\n') break;
                    self.pos += 1;
                }
                continue;
            }
            var cmd: Cmd = .{ .op = .p };
            cmd.a1 = try self.addr(false);
            if (cmd.a1 != null) {
                self.skipBlank();
                if (self.peek() == ',') {
                    self.pos += 1;
                    self.skipBlank();
                    cmd.a2 = (try self.addr(true)) orelse return error.Bad;
                }
                if (cmd.a1.?.kind == .line and cmd.a1.?.n == 0) {
                    const a2 = cmd.a2 orelse return error.Bad;
                    if (a2.kind != .re) return error.Bad;
                    cmd.a1.?.kind = .zero;
                    cmd.active = true;
                }
            }
            self.skipBlank();
            if (self.peek() == '!') {
                cmd.neg = true;
                self.pos += 1;
                self.skipBlank();
                if (self.peek() == '!') return error.Bad;
            }
            const ch = self.peek() orelse return error.Bad;
            self.pos += 1;
            const has_addr = cmd.a1 != null;
            switch (ch) {
                '{' => {
                    cmd.op = .block_open;
                    try self.stack.append(self.a, @intCast(self.cmds.items.len));
                },
                '}' => {
                    if (has_addr or cmd.neg) return error.Bad;
                    const open = self.stack.pop() orelse return error.Bad;
                    cmd.op = .block_close;
                    self.cmds.items[open].jump = @intCast(self.cmds.items.len);
                    try self.endOfCmd();
                },
                '=' => {
                    cmd.op = .eq;
                    try self.endOfCmd();
                },
                'p', 'P', 'd', 'D', 'g', 'G', 'h', 'H', 'x', 'n', 'N' => {
                    cmd.op = switch (ch) {
                        'p' => .p,
                        'P' => .P,
                        'd' => .d,
                        'D' => .D,
                        'g' => .g,
                        'G' => .G,
                        'h' => .h,
                        'H' => .H,
                        'x' => .x,
                        'n' => .n,
                        else => .N,
                    };
                    if (ch == 'n' or ch == 'N' or ch == 'D') self.prog.uses_nd = true;
                    try self.endOfCmd();
                },
                'q', 'Q' => {
                    if (cmd.a2 != null) return error.Bad;
                    cmd.op = if (ch == 'q') .q else .Q;
                    self.skipBlank();
                    if (try self.number()) |n| {
                        if (n > 255) return error.Bad;
                        cmd.code = @intCast(n);
                    }
                    try self.endOfCmd();
                },
                'a', 'i', 'c' => {
                    cmd.op = switch (ch) {
                        'a' => .a,
                        'i' => .i,
                        else => .c,
                    };
                    cmd.text = try self.readText();
                },
                's' => {
                    cmd.op = .s;
                    cmd.sub = try self.parseSub();
                },
                'y' => {
                    cmd.op = .y;
                    cmd.ytab = try self.parseY();
                },
                'b', 't', 'T' => {
                    cmd.op = switch (ch) {
                        'b' => .b,
                        't' => .t,
                        else => .T,
                    };
                    if (ch != 'b') self.prog.uses_t = true;
                    cmd.label = try self.readLabel();
                },
                ':' => {
                    if (has_addr or cmd.neg) return error.Bad;
                    cmd.op = .label;
                    cmd.label = try self.readLabel();
                    if (cmd.label.len == 0) return error.Bad;
                },
                else => return error.Bad,
            }
            try self.cmds.append(self.a, cmd);
        }
        if (self.stack.items.len != 0) return error.Bad;
        for (self.cmds.items, 0..) |*c, idx| {
            switch (c.op) {
                .b, .t, .T => {
                    if (c.label.len == 0) {
                        c.jump = @intCast(self.cmds.items.len);
                        continue;
                    }
                    var found: ?usize = null;
                    for (self.cmds.items, 0..) |*l, li| {
                        if (l.op == .label and std.mem.eql(u8, l.label, c.label)) found = li;
                    }
                    c.jump = @intCast(found orelse return error.Bad);
                },
                .label => for (self.cmds.items[0..idx]) |*l| {
                    if (l.op == .label and std.mem.eql(u8, l.label, c.label)) return error.Bad;
                },
                else => {},
            }
        }
        self.prog.cmds = self.cmds.items;
        self.computeStop();
    }

    fn computeStop(self: *Parser) void {
        const prog = self.prog;
        if (!prog.quiet or prog.cmds.len == 0) return;
        var stop: u64 = 0;
        for (prog.cmds) |c| {
            if (c.op != .p and c.op != .eq) return;
            if (c.neg) return;
            const a1 = c.a1 orelse return;
            if (a1.kind != .line) return;
            var end = a1.n;
            if (c.a2) |a2| switch (a2.kind) {
                .line => end = @max(a1.n, a2.n),
                .plus => end = a1.n +| a2.n,
                else => return,
            };
            stop = @max(stop, end);
        }
        prog.stop_after = stop;
    }
};

const Options = struct {
    quiet: bool = false,
    ere: bool = false,
    pieces: std.ArrayList([]const u8) = .empty,
    operands: std.ArrayList([]const u8) = .empty,

    fn script(self: *Options, a: Allocator) ?[]const u8 {
        if (self.pieces.items.len == 0) {
            if (self.operands.items.len == 0) return null;
            const s = self.operands.items[0];
            self.operands.items = self.operands.items[1..];
            return s;
        }
        return std.mem.join(a, "\n", self.pieces.items) catch null;
    }
};

fn parseArgs(a: Allocator, argv: []const []const u8, err: ?*Io.Writer) !Options {
    var o: Options = .{};
    var p = common.Parser.init(argv, &specs, err);
    while (try p.next()) |it| switch (it) {
        .operand => |s| try o.operands.append(a, s),
        .opt => |m| switch (m.id) {
            'n' => o.quiet = true,
            'E' => o.ere = true,
            'e' => try o.pieces.append(a, m.arg.?),
            else => unreachable,
        },
    };
    return o;
}

fn checkSupported(argv: []const []const u8, env: ?*const common.EnvView) bool {
    var sfa = std.heap.stackFallback(1 << 16, std.heap.page_allocator);
    const a = sfa.get();
    var o = parseArgs(a, argv, null) catch return false;
    const src = o.script(a) orelse return false;
    const utf8 = if (env) |e| common.isUtf8Locale(e) else false;
    if (env) |e| if (common.ctypeKind(e) == .other) return false;
    var prog = Program.init(a, o.quiet, o.ere, utf8);
    defer prog.deinit();
    var ps: Parser = .{ .prog = &prog, .a = prog.arena.allocator(), .src = src };
    ps.parse() catch return false;
    if (prog.uses_t and prog.uses_nd) return false;
    return true;
}

pub fn supports(argv: []const []const u8) bool {
    return checkSupported(argv, null);
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    return checkSupported(argv, env);
}

const Inputs = struct {
    ctx: *Ctx,
    io: Stdio,
    names: []const []const u8,
    idx: usize = 0,
    in: common.Input = .{},
    lr: common.LineReader = undefined,
    open: bool = false,
    bad: bool = false,
    cur: []const u8 = "-",

    fn openNext(self: *Inputs) bool {
        while (self.idx < self.names.len) {
            const name = self.names[self.idx];
            self.idx += 1;
            self.in = .{};
            self.in.open(self.ctx, self.io, name) catch |e| {
                common.errFmt(self.io, "sed", "can't read {s}: {s}", .{ name, common.errnoText(e) });
                self.bad = true;
                continue;
            };
            self.lr = common.LineReader.init(self.ctx.alloc, self.in.r, '\n');
            self.open = true;
            self.cur = name;
            return true;
        }
        return false;
    }

    fn closeCur(self: *Inputs) void {
        if (!self.open) return;
        self.lr.deinit();
        self.in.close();
        self.open = false;
    }

    fn next(self: *Inputs) common.IoError!?common.LineReader.Line {
        while (true) {
            if (!self.open and !self.openNext()) return null;
            if (try self.lr.next()) |l| return l;
            self.closeCur();
        }
    }

    fn hasMore(self: *Inputs) common.IoError!bool {
        while (true) {
            if (self.open) {
                if (self.in.r.bufferedLen() > 0) return true;
                _ = self.in.r.peekByte() catch |e| switch (e) {
                    error.EndOfStream => {
                        self.closeCur();
                        continue;
                    },
                    error.ReadFailed => {
                        self.closeCur();
                        continue;
                    },
                };
                return true;
            }
            if (!self.openNext()) return false;
        }
    }
};

const Err = common.IoError || error{NoRegex};

const Machine = struct {
    ctx: *Ctx,
    prog: *Program,
    out: *Io.Writer,
    inputs: Inputs,
    ps: std.ArrayList(u8) = .empty,
    hs: std.ArrayList(u8) = .empty,
    tmp: std.ArrayList(u8) = .empty,
    aq: std.ArrayList(u8) = .empty,
    ps_nl: bool = true,
    hs_nl: bool = true,
    lineno: u64 = 0,
    missing_nl: bool = false,
    replaced: bool = false,
    last_re: ?*regex.Regex = null,
    exit_code: u8 = 0,

    fn deinit(self: *Machine) void {
        const a = self.ctx.alloc;
        self.ps.deinit(a);
        self.hs.deinit(a);
        self.tmp.deinit(a);
        self.aq.deinit(a);
        self.inputs.closeCur();
    }

    inline fn ensureNl(self: *Machine) Io.Writer.Error!void {
        if (self.missing_nl) {
            self.missing_nl = false;
            try common.putByte(self.out, '\n');
        }
    }

    fn outputPs(self: *Machine, bytes: []const u8, nl: bool) Io.Writer.Error!void {
        try self.ensureNl();
        try common.put(self.out, bytes);
        if (nl) try common.putByte(self.out, '\n') else self.missing_nl = true;
    }

    fn dumpAppend(self: *Machine) Io.Writer.Error!void {
        if (self.aq.items.len == 0) return;
        try self.ensureNl();
        try common.put(self.out, self.aq.items);
        self.aq.clearRetainingCapacity();
    }

    fn readLine(self: *Machine, append: bool) Err!bool {
        try self.dumpAppend();
        const line = (try self.inputs.next()) orelse return false;
        const a = self.ctx.alloc;
        if (append) try self.ps.append(a, '\n') else self.ps.clearRetainingCapacity();
        try self.ps.appendSlice(a, line.bytes);
        self.ps_nl = line.terminated;
        self.lineno += 1;
        return true;
    }

    fn getRe(self: *Machine, idx: u32) ?*regex.Regex {
        const re = if (idx == no_re) self.last_re orelse return null else self.prog.res.items[idx];
        self.last_re = re;
        return re;
    }

    fn matchAddr(self: *Machine, a: Addr) Err!bool {
        switch (a.kind) {
            .line => return self.lineno == a.n,
            .last => return !(try self.inputs.hasMore()),
            .re => {
                const re = self.getRe(a.re) orelse return error.NoRegex;
                return re.isMatch(self.ps.items);
            },
            .step => {
                if (a.step == 0) return self.lineno == a.n;
                return self.lineno >= a.n and (self.lineno - a.n) % a.step == 0;
            },
            .zero, .plus => return false,
        }
    }

    fn matchRange(self: *Machine, c: *Cmd) Err!bool {
        const a2 = c.a2.?;
        if (c.active) {
            switch (a2.kind) {
                .line, .plus => {
                    if (self.lineno >= c.end_line) c.active = false;
                    return self.lineno <= c.end_line;
                },
                .last => {
                    if (!(try self.inputs.hasMore())) c.active = false;
                    return true;
                },
                else => {
                    if (try self.matchAddr(a2)) c.active = false;
                    return true;
                },
            }
        }
        if (!try self.matchAddr(c.a1.?)) return false;
        switch (a2.kind) {
            .line => {
                if (a2.n <= self.lineno) return true;
                c.end_line = a2.n;
            },
            .plus => {
                if (a2.n == 0) return true;
                c.end_line = self.lineno +| a2.n;
            },
            else => {},
        }
        c.active = true;
        return true;
    }

    fn matches(self: *Machine, c: *Cmd) Err!bool {
        const a1 = c.a1 orelse return !c.neg;
        const r = if (c.a2 == null) try self.matchAddr(a1) else try self.matchRange(c);
        return r != c.neg;
    }

    fn findMatch(re: *regex.Regex, hay: []const u8, from: usize) ?regex.Match {
        if (re.literal_only) |l| {
            if (l.len > 0 and !re.must_icase) {
                const s = common.findBytes(hay, l, from) orelse return null;
                return .{ .start = s, .end = s + l.len };
            }
        }
        return re.find(hay, from);
    }

    fn appendCased(self: *Machine, s: []const u8, mode: u8, one: *u8) Err!void {
        const a = self.ctx.alloc;
        if (mode == 0 and one.* == 0) return self.tmp.appendSlice(a, s);
        for (s) |ch| {
            var m = mode;
            if (one.* != 0) {
                m = one.*;
                one.* = 0;
            }
            try self.tmp.append(a, switch (m) {
                1 => std.ascii.toUpper(ch),
                2 => std.ascii.toLower(ch),
                else => ch,
            });
        }
    }

    fn appendRepl(self: *Machine, sub: *const Sub, m: regex.Match, caps: []const usize, have: bool) Err!void {
        const a = self.ctx.alloc;
        const ps = self.ps.items;
        var mode: u8 = 0;
        var one: u8 = 0;
        for (sub.parts) |part| switch (part) {
            .lit => |s| if (sub.cased) try self.appendCased(s, mode, &one) else try self.tmp.appendSlice(a, s),
            .group => |g| {
                var text: []const u8 = "";
                if (g == 0) {
                    text = ps[m.start..m.end];
                } else if (have and g * 2 + 1 < caps.len and caps[g * 2] != unset and caps[g * 2 + 1] != unset) {
                    text = ps[caps[g * 2]..caps[g * 2 + 1]];
                }
                if (sub.cased) try self.appendCased(text, mode, &one) else try self.tmp.appendSlice(a, text);
            },
            .upper => mode = 1,
            .lower => mode = 2,
            .upper1 => one = 1,
            .lower1 => one = 2,
            .end_case => mode = 0,
        };
    }

    fn subst(self: *Machine, sub: *const Sub) Err!bool {
        const re = self.getRe(sub.re) orelse return error.NoRegex;
        const ps = self.ps.items;
        if (!re.isMatch(ps)) return false;
        const a = self.ctx.alloc;
        self.tmp.clearRetainingCapacity();
        var pos: usize = 0;
        var count: u32 = 0;
        var prev_end: usize = unset;
        var did = false;
        var capbuf: [regex.max_caps * 2]usize = undefined;
        while (pos <= ps.len) {
            const m = findMatch(re, ps, pos) orelse break;
            if (m.start == m.end and m.start == prev_end) {
                if (m.start >= ps.len) break;
                try self.tmp.appendSlice(a, ps[pos .. m.start + 1]);
                pos = m.start + 1;
                prev_end = unset;
                continue;
            }
            try self.tmp.appendSlice(a, ps[pos..m.start]);
            count += 1;
            prev_end = m.end;
            if (count < sub.nth) {
                try self.tmp.appendSlice(a, ps[m.start..m.end]);
                if (m.end == m.start) {
                    if (m.end < ps.len) try self.tmp.append(a, ps[m.end]);
                    pos = m.end + 1;
                } else pos = m.end;
                continue;
            }
            var have = false;
            const caps = capbuf[0..re.ncaps()];
            if (sub.groups) have = re.pike(ps, m.start, caps) and caps[0] == m.start;
            try self.appendRepl(sub, m, caps, have);
            did = true;
            if (!sub.global) {
                pos = m.end;
                break;
            }
            if (m.end == m.start) {
                if (m.end < ps.len) try self.tmp.append(a, ps[m.end]);
                pos = m.end + 1;
            } else pos = m.end;
        }
        if (!did) return false;
        if (pos < ps.len) try self.tmp.appendSlice(a, ps[pos..]);
        std.mem.swap(std.ArrayList(u8), &self.ps, &self.tmp);
        return true;
    }

    fn run(self: *Machine) Err!void {
        const a = self.ctx.alloc;
        const cmds = self.prog.cmds;
        const quiet = self.prog.quiet;
        var restart = false;
        while (true) {
            if (!restart) {
                if (!try self.readLine(false)) break;
            }
            restart = false;
            self.replaced = false;
            var pc: usize = 0;
            var autoprint = true;
            cycle: while (pc < cmds.len) {
                const c = &cmds[pc];
                if (!try self.matches(c)) {
                    pc = if (c.op == .block_open) c.jump else pc + 1;
                    continue;
                }
                pc += 1;
                switch (c.op) {
                    .block_open, .block_close, .label => {},
                    .p => try self.outputPs(self.ps.items, self.ps_nl),
                    .P => {
                        const s = self.ps.items;
                        if (std.mem.findScalar(u8, s, '\n')) |e| {
                            try self.outputPs(s[0..e], true);
                        } else try self.outputPs(s, self.ps_nl);
                    },
                    .d => {
                        autoprint = false;
                        break :cycle;
                    },
                    .D => {
                        autoprint = false;
                        if (std.mem.findScalar(u8, self.ps.items, '\n')) |i| {
                            const rest = self.ps.items.len - i - 1;
                            std.mem.copyForwards(u8, self.ps.items[0..rest], self.ps.items[i + 1 ..]);
                            self.ps.items.len = rest;
                            restart = true;
                            try self.dumpAppend();
                        }
                        break :cycle;
                    },
                    .n => {
                        if (!try self.inputs.hasMore()) break :cycle;
                        if (!quiet) try self.outputPs(self.ps.items, self.ps_nl);
                        _ = try self.readLine(false);
                    },
                    .N => {
                        if (!try self.inputs.hasMore()) break :cycle;
                        _ = try self.readLine(true);
                    },
                    .g => {
                        self.ps.clearRetainingCapacity();
                        try self.ps.appendSlice(a, self.hs.items);
                        self.ps_nl = self.hs_nl;
                    },
                    .G => {
                        try self.ps.append(a, '\n');
                        try self.ps.appendSlice(a, self.hs.items);
                        self.ps_nl = self.hs_nl;
                    },
                    .h => {
                        self.hs.clearRetainingCapacity();
                        try self.hs.appendSlice(a, self.ps.items);
                        self.hs_nl = self.ps_nl;
                    },
                    .H => {
                        try self.hs.append(a, '\n');
                        try self.hs.appendSlice(a, self.ps.items);
                        self.hs_nl = self.ps_nl;
                    },
                    .x => {
                        std.mem.swap(std.ArrayList(u8), &self.ps, &self.hs);
                        std.mem.swap(bool, &self.ps_nl, &self.hs_nl);
                    },
                    .s => {
                        if (try self.subst(c.sub.?)) {
                            self.replaced = true;
                            if (c.sub.?.print) try self.outputPs(self.ps.items, self.ps_nl);
                        }
                    },
                    .y => {
                        const tab = c.ytab.?;
                        for (self.ps.items) |*b| b.* = tab[b.*];
                    },
                    .q => {
                        if (!quiet) try self.outputPs(self.ps.items, self.ps_nl);
                        try self.dumpAppend();
                        try self.ensureNl();
                        self.exit_code = c.code;
                        return;
                    },
                    .Q => {
                        self.exit_code = c.code;
                        return;
                    },
                    .eq => {
                        try self.ensureNl();
                        try common.putUint(self.out, self.lineno);
                        try common.putByte(self.out, '\n');
                    },
                    .a => try self.aq.appendSlice(a, c.text),
                    .i => {
                        try self.ensureNl();
                        try common.put(self.out, c.text);
                    },
                    .c => {
                        if (c.a2 == null or !c.active) {
                            try self.ensureNl();
                            try common.put(self.out, c.text);
                        }
                        autoprint = false;
                        break :cycle;
                    },
                    .b => pc = c.jump,
                    .t => if (self.replaced) {
                        self.replaced = false;
                        pc = c.jump;
                    },
                    .T => if (!self.replaced) {
                        pc = c.jump;
                    } else {
                        self.replaced = false;
                    },
                }
            }
            if (autoprint and !quiet) try self.outputPs(self.ps.items, self.ps_nl);
            if (self.prog.stop_after) |s| if (self.lineno >= s and self.inputs.names.len <= 1) break;
        }
        try self.dumpAppend();
    }
};

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog_name = argv[0];
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    var o = parseArgs(aa, argv, io.err) catch return 1;
    const src = o.script(aa) orelse {
        common.errRaw(io, "Usage: {s} [OPTION]... {{script-only-if-no-other-script}} [input-file]...\n", .{prog_name});
        return 1;
    };
    var prog = Program.init(ctx.alloc, o.quiet, o.ere, common.isUtf8Locale(ctx.env));
    defer prog.deinit();
    var ps: Parser = .{ .prog = &prog, .a = prog.arena.allocator(), .src = src };
    ps.parse() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => {
            common.errFmt(io, prog_name, "-e expression #1, char {d}: unsupported or invalid script", .{ps.pos});
            return 1;
        },
    };
    var names: []const []const u8 = o.operands.items;
    if (names.len == 0) names = &.{"-"};
    var m: Machine = .{
        .ctx = ctx,
        .prog = &prog,
        .out = io.out,
        .inputs = .{ .ctx = ctx, .io = io, .names = names },
    };
    defer m.deinit();
    m.run() catch |e| switch (e) {
        error.NoRegex => {
            common.errLine(io, prog_name, "no previous regular expression");
            return 1;
        },
        error.ReadFailed => {
            io.out.flush() catch {};
            const nm = if (m.inputs.in.stdin) "stdin" else m.inputs.cur;
            common.errFmt(io, prog_name, "read error on {s}: {s}", .{ nm, m.inputs.in.readErr() });
            return 4;
        },
        else => |other| return other,
    };
    if (m.exit_code != 0) return m.exit_code;
    return if (m.inputs.bad) 2 else 0;
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8, status: u8) !void {
    return common.expectRun(run, argv, input, want, status);
}

test "sed substitute" {
    try t(&.{ "sed", "s/a/b/" }, "aaa\nxax\n", "baa\nxbx\n", 0);
    try t(&.{ "sed", "s/a/b/g" }, "aaa\n", "bbb\n", 0);
    try t(&.{ "sed", "s/a/b/2" }, "aaa\n", "aba\n", 0);
    try t(&.{ "sed", "s/a/b/2g" }, "aaaa\n", "abbb\n", 0);
    try t(&.{ "sed", "s/b*/X/g" }, "abc\n", "XaXcX\n", 0);
    try t(&.{ "sed", "-E", "s/(a+)(b+)/\\2\\1/" }, "aabbb\n", "bbbaa\n", 0);
    try t(&.{ "sed", "s/\\(h\\)\\(w\\)/[\\1&\\2]/" }, "hw\n", "[hhww]\n", 0);
    try t(&.{ "sed", "s/o/0/gp" }, "foo\n", "f00\nf00\n", 0);
    try t(&.{ "sed", "-n", "s/o/0/p" }, "foo\nbar\n", "f0o\n", 0);
    try t(&.{ "sed", "s|a/b|X|" }, "a/b\n", "X\n", 0);
    try t(&.{ "sed", "s/\\(hello\\) \\(world\\)/\\u\\1 \\U\\2\\E!/" }, "hello world\n", "Hello WORLD!\n", 0);
    try t(&.{ "sed", "s/x/a\\nb/" }, "x\n", "a\nb\n", 0);
}

test "sed addresses" {
    try t(&.{ "sed", "-n", "2,3p" }, "1\n2\n3\n4\n", "2\n3\n", 0);
    try t(&.{ "sed", "-n", "$p" }, "1\n2\n3", "3", 0);
    try t(&.{ "sed", "-n", "/b/,/d/p" }, "a\nb\nc\nd\ne\n", "b\nc\nd\n", 0);
    try t(&.{ "sed", "-n", "2,+1p" }, "1\n2\n3\n4\n", "2\n3\n", 0);
    try t(&.{ "sed", "-n", "1~2p" }, "1\n2\n3\n4\n", "1\n3\n", 0);
    try t(&.{ "sed", "-n", "0,/a/p" }, "a\na\n", "a\n", 0);
    try t(&.{ "sed", "2!d" }, "1\n2\n3\n", "2\n", 0);
    try t(&.{ "sed", "-n", "3,1p" }, "1\n2\n3\n4\n", "3\n", 0);
}

test "sed commands" {
    try t(&.{ "sed", "2q" }, "1\n2\n3\n", "1\n2\n", 0);
    try t(&.{ "sed", "2q5" }, "1\n2\n3\n", "1\n2\n", 5);
    try t(&.{ "sed", "2Q" }, "1\n2\n3\n", "1\n", 0);
    try t(&.{ "sed", "1!G;h;$!d" }, "1\n2\n3\n", "3\n2\n1\n", 0);
    try t(&.{ "sed", ":a;N;$!ba;s/\\n/ /g" }, "1\n2\n3\n", "1 2 3\n", 0);
    try t(&.{ "sed", "$!N;P;D" }, "1\n2\n3\n", "1\n2\n3\n", 0);
    try t(&.{ "sed", "y/abc/xyz/" }, "aabbcc\n", "xxyyzz\n", 0);
    try t(&.{ "sed", "-n", "$=" }, "a\nb\nc\n", "3\n", 0);
    try t(&.{ "sed", "1i\\  ind" }, "x\n", "  ind\nx\n", 0);
    try t(&.{ "sed", "$a end" }, "a\nb", "a\nb\nend\n", 0);
    try t(&.{ "sed", "2,3c X" }, "1\n2\n3\n4\n", "1\nX\n4\n", 0);
    try t(&.{ "sed", "p" }, "abc", "abc\nabc", 0);
    try t(&.{ "sed", "n;d" }, "1\n2\n3\n", "1\n3\n", 0);
    try t(&.{ "sed", "-n", "2{p;q}" }, "1\n2\n3\n", "2\n", 0);
    try t(&.{ "sed", "-e", "s/a/b/", "-e", "s/b/c/" }, "a\n", "c\n", 0);
}

test "sed supports" {
    try std.testing.expect(supports(&.{ "sed", "-n", "5,15p", "f" }));
    try std.testing.expect(supports(&.{ "sed", "s/a/b/g" }));
    try std.testing.expect(supports(&.{ "sed", "-E", "-e", "s/(a)/\\1/" }));
    try std.testing.expect(!supports(&.{ "sed", "-i", "s/a/b/" }));
    try std.testing.expect(!supports(&.{ "sed", "-f", "x" }));
    try std.testing.expect(!supports(&.{ "sed", "w out" }));
    try std.testing.expect(!supports(&.{ "sed", "r x" }));
    try std.testing.expect(!supports(&.{ "sed", "s/a/b/w x" }));
    try std.testing.expect(!supports(&.{ "sed", "-E", "s/(a|b)/\\1/" }));
    try std.testing.expect(!supports(&.{ "sed", "s/a/b" }));
    try std.testing.expect(!supports(&.{"sed"}));
}

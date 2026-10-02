const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const specs = [_]common.OptSpec{
    .{ .id = 'c', .short = 'c', .long = "complement" },
    .{ .id = 'c', .short = 'C' },
    .{ .id = 'd', .short = 'd', .long = "delete" },
    .{ .id = 's', .short = 's', .long = "squeeze-repeats" },
    .{ .id = 't', .short = 't', .long = "truncate-set1" },
};

const Class = enum { alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit };

fn inClass(cls: Class, c: u8) bool {
    return switch (cls) {
        .alnum => std.ascii.isAlphanumeric(c),
        .alpha => std.ascii.isAlphabetic(c),
        .blank => c == ' ' or c == '\t',
        .cntrl => c < 32 or c == 127,
        .digit => c >= '0' and c <= '9',
        .graph => c > 32 and c < 127,
        .lower => c >= 'a' and c <= 'z',
        .print => c >= 32 and c < 127,
        .punct => c > 32 and c < 127 and !std.ascii.isAlphanumeric(c),
        .space => (c >= 9 and c <= 13) or c == 32,
        .upper => c >= 'A' and c <= 'Z',
        .xdigit => std.ascii.isHex(c),
    };
}

const Tok = struct { c: u8, esc: bool };

fn tokenize(alloc: std.mem.Allocator, s: []const u8) !?[]Tok {
    var out: std.ArrayList(Tok) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c != '\\') {
            try out.append(alloc, .{ .c = c, .esc = false });
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) return null;
        const e = s[i];
        switch (e) {
            'a' => try out.append(alloc, .{ .c = 7, .esc = true }),
            'b' => try out.append(alloc, .{ .c = 8, .esc = true }),
            'f' => try out.append(alloc, .{ .c = 12, .esc = true }),
            'n' => try out.append(alloc, .{ .c = 10, .esc = true }),
            'r' => try out.append(alloc, .{ .c = 13, .esc = true }),
            't' => try out.append(alloc, .{ .c = 9, .esc = true }),
            'v' => try out.append(alloc, .{ .c = 11, .esc = true }),
            '\\' => try out.append(alloc, .{ .c = '\\', .esc = true }),
            '0'...'7' => {
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (n += 1) {
                    v = v * 8 + (s[i] - '0');
                    i += 1;
                }
                if (v > 255) return null;
                try out.append(alloc, .{ .c = @intCast(v), .esc = true });
                continue;
            },
            else => try out.append(alloc, .{ .c = e, .esc = true }),
        }
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

const Set = struct {
    chars: std.ArrayList(u8) = .empty,
    fill_at: ?usize = null,
    fill_char: u8 = 0,
    classes: u8 = 0,
    first_class: ?Class = null,

    fn deinit(self: *Set, alloc: std.mem.Allocator) void {
        self.chars.deinit(alloc);
    }
};

fn findClose(toks: []const Tok, from: usize, delim: u8) ?usize {
    var j = from;
    while (j + 1 < toks.len) : (j += 1) {
        if (!toks[j].esc and toks[j].c == delim and !toks[j + 1].esc and toks[j + 1].c == ']') return j;
    }
    return null;
}

const ParseErr = error{ Unsupported, OutOfMemory };

fn parseSet(alloc: std.mem.Allocator, s: []const u8, second: bool) ParseErr!Set {
    const toks = (try tokenize(alloc, s)) orelse return error.Unsupported;
    defer alloc.free(toks);
    var set: Set = .{};
    errdefer set.deinit(alloc);
    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        if (!t.esc and t.c == '[' and i + 1 < toks.len and !toks[i + 1].esc) {
            const k = toks[i + 1].c;
            if (k == ':') {
                const close = findClose(toks, i + 2, ':') orelse return error.Unsupported;
                var name: [16]u8 = undefined;
                const nlen = close - (i + 2);
                if (nlen == 0 or nlen > name.len) return error.Unsupported;
                for (toks[i + 2 .. close], 0..) |nt, ni| {
                    if (nt.esc) return error.Unsupported;
                    name[ni] = nt.c;
                }
                const cls = std.meta.stringToEnum(Class, name[0..nlen]) orelse return error.Unsupported;
                if (set.first_class == null) set.first_class = cls;
                set.classes += 1;
                var c: usize = 0;
                while (c < 256) : (c += 1) if (inClass(cls, @intCast(c))) try set.chars.append(alloc, @intCast(c));
                i = close + 2;
                continue;
            } else if (k == '=') {
                if (second) return error.Unsupported;
                const close = findClose(toks, i + 2, '=') orelse return error.Unsupported;
                if (close - (i + 2) != 1) return error.Unsupported;
                try set.chars.append(alloc, toks[i + 2].c);
                i = close + 2;
                continue;
            } else if (i + 2 < toks.len and !toks[i + 2].esc and toks[i + 2].c == '*') {
                var j = i + 3;
                var n: u64 = 0;
                var base: u64 = 10;
                if (j < toks.len and !toks[j].esc and toks[j].c == '0') base = 8;
                var any = false;
                while (j < toks.len and !toks[j].esc and toks[j].c >= '0' and toks[j].c <= '9') : (j += 1) {
                    if (base == 8 and toks[j].c > '7') return error.Unsupported;
                    n = n * base + (toks[j].c - '0');
                    if (n > 1 << 20) return error.Unsupported;
                    any = true;
                }
                if (j < toks.len and !toks[j].esc and toks[j].c == ']') {
                    if (!second) return error.Unsupported;
                    const ch = toks[i + 1].c;
                    if (!any or n == 0) {
                        if (set.fill_at != null) return error.Unsupported;
                        set.fill_at = set.chars.items.len;
                        set.fill_char = ch;
                    } else {
                        var r: u64 = 0;
                        while (r < n) : (r += 1) try set.chars.append(alloc, ch);
                    }
                    i = j + 1;
                    continue;
                }
            }
        }
        if (i + 2 < toks.len and !toks[i + 1].esc and toks[i + 1].c == '-') {
            const hi = toks[i + 2].c;
            if (hi < t.c) return error.Unsupported;
            var c: usize = t.c;
            while (c <= hi) : (c += 1) try set.chars.append(alloc, @intCast(c));
            i += 3;
            continue;
        }
        try set.chars.append(alloc, t.c);
        i += 1;
    }
    return set;
}

const Plan = struct {
    map: [256]u8,
    delete: [256]bool,
    squeeze: [256]bool,
    do_delete: bool,
    do_squeeze: bool,
    translate: bool,
};

const Parsed = struct {
    complement: bool = false,
    delete: bool = false,
    squeeze: bool = false,
    truncate: bool = false,
    operands: [2][]const u8 = undefined,
    nops: usize = 0,
};

fn parseArgs(argv: []const []const u8, err: ?*Io.Writer) ?Parsed {
    var pr: Parsed = .{};
    var p = common.Parser.init(argv, &specs, err);
    while (true) {
        const it = (p.next() catch return null) orelse break;
        switch (it) {
            .operand => |o| {
                if (pr.nops >= 2) return null;
                pr.operands[pr.nops] = o;
                pr.nops += 1;
            },
            .opt => |m| switch (m.id) {
                'c' => pr.complement = true,
                'd' => pr.delete = true,
                's' => pr.squeeze = true,
                't' => pr.truncate = true,
                else => unreachable,
            },
        }
    }
    return pr;
}

fn buildPlan(alloc: std.mem.Allocator, pr: Parsed) ParseErr!Plan {
    var plan: Plan = .{
        .map = undefined,
        .delete = [_]bool{false} ** 256,
        .squeeze = [_]bool{false} ** 256,
        .do_delete = pr.delete,
        .do_squeeze = pr.squeeze,
        .translate = false,
    };
    for (&plan.map, 0..) |*m, i| m.* = @intCast(i);
    const need2 = !pr.delete or pr.squeeze;
    if (pr.nops == 0) return error.Unsupported;
    if (pr.delete and !pr.squeeze and pr.nops != 1) return error.Unsupported;
    if (pr.delete and pr.squeeze and pr.nops != 2) return error.Unsupported;
    if (!pr.delete and !pr.squeeze and pr.nops != 2) return error.Unsupported;
    if (!pr.delete and pr.squeeze and pr.nops > 2) return error.Unsupported;
    if (pr.truncate and pr.delete) return error.Unsupported;
    _ = need2;
    var s1 = try parseSet(alloc, pr.operands[0], false);
    defer s1.deinit(alloc);
    var in1 = [_]bool{false} ** 256;
    for (s1.chars.items) |c| in1[c] = true;
    if (pr.complement) {
        s1.chars.clearRetainingCapacity();
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            in1[c] = !in1[c];
            if (in1[c]) try s1.chars.append(alloc, @intCast(c));
        }
    }
    if (pr.delete) {
        plan.delete = in1;
        if (pr.squeeze) {
            var s2 = try parseSet(alloc, pr.operands[1], true);
            defer s2.deinit(alloc);
            if (s2.classes > 0 or s2.fill_at != null) return error.Unsupported;
            for (s2.chars.items) |c| plan.squeeze[c] = true;
        }
        return plan;
    }
    if (pr.nops == 1) {
        plan.squeeze = in1;
        return plan;
    }
    var s2 = try parseSet(alloc, pr.operands[1], true);
    defer s2.deinit(alloc);
    if (s2.classes > 0) {
        const ok = !pr.complement and s1.classes == 1 and s2.classes == 1 and s1.chars.items.len == 26 and s2.chars.items.len == 26 and
            ((s1.first_class.? == .lower and s2.first_class.? == .upper) or (s1.first_class.? == .upper and s2.first_class.? == .lower));
        if (!ok) return error.Unsupported;
    }
    if (pr.complement and s1.classes > 0) {
        var one = true;
        for (s2.chars.items) |c| {
            if (c != s2.chars.items[0]) one = false;
        }
        const single = s2.chars.items.len == 1 or (s2.chars.items.len == 0 and s2.fill_at != null);
        if (!one or !(single or s2.fill_at != null)) return error.Unsupported;
    }
    if (s2.fill_at) |at| {
        const base = s2.chars.items.len;
        if (s1.chars.items.len > base) {
            const extra = s1.chars.items.len - base;
            var filled: std.ArrayList(u8) = .empty;
            errdefer filled.deinit(alloc);
            try filled.appendSlice(alloc, s2.chars.items[0..at]);
            try filled.appendNTimes(alloc, s2.fill_char, extra);
            try filled.appendSlice(alloc, s2.chars.items[at..]);
            s2.chars.deinit(alloc);
            s2.chars = filled;
        }
    }
    var n1 = s1.chars.items.len;
    if (pr.truncate) n1 = @min(n1, s2.chars.items.len);
    if (n1 > 0 and s2.chars.items.len == 0) return error.Unsupported;
    plan.translate = true;
    var i: usize = 0;
    while (i < n1) : (i += 1) {
        const to = if (i < s2.chars.items.len) s2.chars.items[i] else s2.chars.items[s2.chars.items.len - 1];
        plan.map[s1.chars.items[i]] = to;
    }
    if (pr.squeeze) {
        for (s2.chars.items) |c| plan.squeeze[c] = true;
    }
    return plan;
}

pub fn supports(argv: []const []const u8) bool {
    const pr = parseArgs(argv, null) orelse return false;
    var buf: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    _ = buildPlan(fba.allocator(), pr) catch return false;
    return true;
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog = argv[0];
    const pr = parseArgs(argv, io.err) orelse return 1;
    const plan = buildPlan(ctx.alloc, pr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            common.errLine(io, prog, "invalid operands");
            return 1;
        },
    };
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(ctx.alloc);
    var last: i16 = -1;
    while (common.nextChunk(io.in) catch {
        common.errLine(io, prog, "read error");
        return 1;
    }) |chunk| {
        try scratch.ensureTotalCapacity(ctx.alloc, chunk.len);
        const out = scratch.allocatedSlice()[0..chunk.len];
        const n = transform(&plan, chunk, out, &last);
        try common.put(io.out, out[0..n]);
    }
    return 0;
}

fn transform(plan: *const Plan, in: []const u8, out: []u8, last: *i16) usize {
    var n: usize = 0;
    if (!plan.do_delete and !plan.do_squeeze) {
        for (in, 0..) |b, i| out[i] = plan.map[b];
        return in.len;
    }
    if (plan.do_delete and !plan.do_squeeze) {
        for (in) |b| {
            out[n] = b;
            n += @intFromBool(!plan.delete[b]);
        }
        return n;
    }
    var l = last.*;
    for (in) |b| {
        if (plan.do_delete and plan.delete[b]) continue;
        const o = plan.map[b];
        if (plan.squeeze[o] and l == o) continue;
        out[n] = o;
        n += 1;
        l = o;
    }
    last.* = l;
    return n;
}

fn tt(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "tr translate" {
    try tt(&.{ "tr", "a-z", "A-Z" }, "hello World\n", "HELLO WORLD\n");
    try tt(&.{ "tr", "[:lower:]", "[:upper:]" }, "hello\n", "HELLO\n");
    try tt(&.{ "tr", "abc", "x" }, "aabbcc d\n", "xxxxxx d\n");
    try tt(&.{ "tr", "a-c", "[x*]" }, "abcd", "xxxd");
    try tt(&.{ "tr", "-t", "abc", "xy" }, "abc", "xyc");
    try tt(&.{ "tr", "\\n", " " }, "a\nb\n", "a b ");
    try tt(&.{ "tr", "-c", "a", "\\n" }, "abc", "a\n\n");
}

test "tr delete and squeeze" {
    try tt(&.{ "tr", "-d", "[:digit:]" }, "a1b22c", "abc");
    try tt(&.{ "tr", "-s", " " }, "a   b  c", "a b c");
    try tt(&.{ "tr", "-cs", "a-zA-Z", "\\n" }, "hello, world!  x", "hello\nworld\nx");
    try tt(&.{ "tr", "-ds", "a", "x" }, "xaxxaxb", "xb");
    try tt(&.{ "tr", "-cd", "a-c" }, "abcdef\n", "abc");
    try tt(&.{ "tr", "-s", "ab", "xy" }, "aabbab", "xyxy");
}

test "tr supports" {
    try std.testing.expect(supports(&.{ "tr", "a-z", "A-Z" }));
    try std.testing.expect(supports(&.{ "tr", "-d", "\\r" }));
    try std.testing.expect(!supports(&.{ "tr", "z-a", "x" }));
    try std.testing.expect(!supports(&.{ "tr", "[:upper:]", "[:digit:]" }));
    try std.testing.expect(!supports(&.{"tr"}));
    try std.testing.expect(!supports(&.{ "tr", "-d", "a", "b" }));
    try std.testing.expect(!supports(&.{ "tr", "a", "b", "c" }));
}

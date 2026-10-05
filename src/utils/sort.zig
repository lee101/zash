const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const prog = "sort";
const max_keys = 8;
const none = std.math.maxInt(usize);

const specs = [_]common.OptSpec{
    .{ .id = 'n', .short = 'n', .long = "numeric-sort" },
    .{ .id = 'r', .short = 'r', .long = "reverse" },
    .{ .id = 'u', .short = 'u', .long = "unique" },
    .{ .id = 's', .short = 's', .long = "stable" },
    .{ .id = 'f', .short = 'f', .long = "ignore-case" },
    .{ .id = 'b', .short = 'b', .long = "ignore-leading-blanks" },
    .{ .id = 'z', .short = 'z', .long = "zero-terminated" },
    .{ .id = 'c', .short = 'c' },
    .{ .id = 'c', .long = "check", .arg = .optional },
    .{ .id = 'C', .short = 'C' },
    .{ .id = 'k', .short = 'k', .long = "key", .arg = .required },
    .{ .id = 't', .short = 't', .long = "field-separator", .arg = .required },
    .{ .id = 'o', .short = 'o', .long = "output", .arg = .required },
    .{ .id = 'S', .short = 'S', .long = "buffer-size", .arg = .required },
    .{ .id = 'T', .short = 'T', .long = "temporary-directory", .arg = .required },
    .{ .id = 'P', .long = "parallel", .arg = .required },
    .{ .id = 'Y', .long = "sort", .arg = .required },
};

const Key = struct {
    sword: usize = 0,
    schar: usize = 0,
    eword: usize = none,
    echar: usize = 0,
    skip_sb: bool = false,
    skip_eb: bool = false,
    numeric: bool = false,
    fold: bool = false,
    reverse: bool = false,

    fn isDefault(k: Key) bool {
        return !(k.skip_sb or k.skip_eb or k.numeric or k.fold);
    }
};

const Check = enum { off, diag, quiet };

const Config = struct {
    keys: [max_keys]Key = undefined,
    nkeys: usize = 0,
    g_n: bool = false,
    g_f: bool = false,
    g_b: bool = false,
    g_r: bool = false,
    unique: bool = false,
    stable: bool = false,
    zero: bool = false,
    check: Check = .off,
    tab: ?u8 = null,
    output: ?[]const u8 = null,
    nfiles: usize = 0,
};

fn digits(s: []const u8, i: *usize) ?usize {
    const start = i.*;
    var v: usize = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
        if (i.* - start >= 9) return null;
        v = v * 10 + (s[i.*] - '0');
    }
    if (i.* == start) return null;
    return v;
}

fn parseKey(s: []const u8) ?Key {
    var k: Key = .{};
    var i: usize = 0;
    const f1 = digits(s, &i) orelse return null;
    if (f1 == 0) return null;
    k.sword = f1 - 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const c = digits(s, &i) orelse return null;
        if (c == 0) return null;
        k.schar = c - 1;
    }
    while (i < s.len and s[i] != ',') : (i += 1) switch (s[i]) {
        'b' => k.skip_sb = true,
        'n' => k.numeric = true,
        'r' => k.reverse = true,
        'f' => k.fold = true,
        else => return null,
    };
    if (i < s.len) {
        i += 1;
        const f2 = digits(s, &i) orelse return null;
        if (f2 == 0) return null;
        k.eword = f2 - 1;
        if (i < s.len and s[i] == '.') {
            i += 1;
            k.echar = digits(s, &i) orelse return null;
        }
        while (i < s.len) : (i += 1) switch (s[i]) {
            'b' => k.skip_eb = true,
            'n' => k.numeric = true,
            'r' => k.reverse = true,
            'f' => k.fold = true,
            else => return null,
        };
    }
    return k;
}

fn validBufSize(s: []const u8) bool {
    var i: usize = 0;
    const v = digits(s, &i) orelse return false;
    if (v == 0) return false;
    const rest = s[i..];
    if (rest.len == 0) return true;
    return rest.len == 1 and (rest[0] == 'K' or rest[0] == 'M' or rest[0] == 'G');
}

fn parseArgs(argv: []const []const u8, err: ?*Io.Writer, files: ?*std.ArrayList([]const u8), alloc: std.mem.Allocator) !?Config {
    var cfg: Config = .{};
    var p = common.Parser.init(argv, &specs, err);
    var tab_set = false;
    while (true) {
        const it = (p.next() catch return null) orelse break;
        switch (it) {
            .operand => |o| {
                if (o.len > 1 and o[0] == '+') return null;
                cfg.nfiles += 1;
                if (files) |f| try f.append(alloc, o);
            },
            .opt => |m| switch (m.id) {
                'n' => cfg.g_n = true,
                'r' => cfg.g_r = true,
                'u' => cfg.unique = true,
                's' => cfg.stable = true,
                'f' => cfg.g_f = true,
                'b' => cfg.g_b = true,
                'z' => cfg.zero = true,
                'c' => {
                    if (m.arg) |a| {
                        if (std.mem.eql(u8, a, "diagnose-first")) {
                            cfg.check = .diag;
                        } else if (std.mem.eql(u8, a, "quiet") or std.mem.eql(u8, a, "silent")) {
                            cfg.check = .quiet;
                        } else return null;
                    } else cfg.check = .diag;
                },
                'C' => cfg.check = .quiet,
                'k' => {
                    if (cfg.nkeys >= max_keys) return null;
                    cfg.keys[cfg.nkeys] = parseKey(m.arg.?) orelse return null;
                    cfg.nkeys += 1;
                },
                't' => {
                    const a = m.arg.?;
                    if (a.len != 1) return null;
                    if (tab_set and cfg.tab.? != a[0]) return null;
                    tab_set = true;
                    cfg.tab = a[0];
                },
                'o' => cfg.output = m.arg.?,
                'S' => if (!validBufSize(m.arg.?)) return null,
                'T' => {},
                'P' => {
                    var i: usize = 0;
                    const v = digits(m.arg.?, &i) orelse return null;
                    if (v == 0 or i != m.arg.?.len) return null;
                },
                'Y' => {
                    if (std.mem.eql(u8, m.arg.?, "numeric")) cfg.g_n = true else return null;
                },
                else => unreachable,
            },
        }
    }
    if (cfg.check != .off) {
        if (cfg.output != null or cfg.nfiles > 1 or cfg.zero) return null;
    }
    if (cfg.nkeys == 0) {
        if (cfg.g_n or cfg.g_f or cfg.g_b) {
            cfg.keys[0] = .{ .numeric = cfg.g_n, .fold = cfg.g_f, .skip_sb = cfg.g_b, .skip_eb = cfg.g_b, .reverse = cfg.g_r };
            cfg.nkeys = 1;
        }
    } else {
        for (cfg.keys[0..cfg.nkeys]) |*k| {
            if (k.isDefault() and !k.reverse) {
                k.numeric = cfg.g_n;
                k.fold = cfg.g_f;
                k.skip_sb = cfg.g_b;
                k.skip_eb = cfg.g_b;
                k.reverse = cfg.g_r;
            }
        }
    }
    return cfg;
}

pub fn supports(argv: []const []const u8) bool {
    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const cfg = parseArgs(argv, null, null, fba.allocator()) catch return false;
    return cfg != null;
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    _ = argv;
    if (env.get("POSIXLY_CORRECT") != null or env.get("_POSIX2_VERSION") != null) return false;
    return common.localeIsCLike(env, "LC_COLLATE") and common.localeIsCLike(env, "LC_NUMERIC");
}

inline fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn begField(line: []const u8, k: Key, tab: ?u8) usize {
    var ptr: usize = 0;
    const lim = line.len;
    var sword = k.sword;
    if (tab) |tc| {
        while (ptr < lim and sword != 0) {
            sword -= 1;
            while (ptr < lim and line[ptr] != tc) ptr += 1;
            if (ptr < lim) ptr += 1;
        }
    } else {
        while (ptr < lim and sword != 0) {
            sword -= 1;
            while (ptr < lim and isBlank(line[ptr])) ptr += 1;
            while (ptr < lim and !isBlank(line[ptr])) ptr += 1;
        }
    }
    if (k.skip_sb) {
        while (ptr < lim and isBlank(line[ptr])) ptr += 1;
    }
    return @min(lim, ptr +| k.schar);
}

fn limField(line: []const u8, k: Key, tab: ?u8) usize {
    const lim = line.len;
    if (k.eword == none) return lim;
    var ptr: usize = 0;
    var eword = k.eword;
    const echar = k.echar;
    if (echar == 0) eword += 1;
    if (tab) |tc| {
        while (ptr < lim and eword != 0) {
            eword -= 1;
            while (ptr < lim and line[ptr] != tc) ptr += 1;
            if (ptr < lim and (eword != 0 or echar != 0)) ptr += 1;
        }
    } else {
        while (ptr < lim and eword != 0) {
            eword -= 1;
            while (ptr < lim and isBlank(line[ptr])) ptr += 1;
            while (ptr < lim and !isBlank(line[ptr])) ptr += 1;
        }
    }
    if (echar != 0) {
        if (k.skip_eb) {
            while (ptr < lim and isBlank(line[ptr])) ptr += 1;
        }
        ptr = @min(lim, ptr +| echar);
    }
    return ptr;
}

const Num = struct { neg: bool, int: []const u8, frac: []const u8 };

fn parseNum(s: []const u8) Num {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const is = i;
    while (i < s.len and isDigit(s[i])) i += 1;
    var int = s[is..i];
    var frac: []const u8 = &.{};
    if (i < s.len and s[i] == '.') {
        const fs = i + 1;
        var j = fs;
        while (j < s.len and isDigit(s[j])) j += 1;
        frac = s[fs..j];
    }
    while (int.len > 0 and int[0] == '0') int = int[1..];
    while (frac.len > 0 and frac[frac.len - 1] == '0') frac = frac[0 .. frac.len - 1];
    if (int.len == 0 and frac.len == 0) neg = false;
    return .{ .neg = neg, .int = int, .frac = frac };
}

inline fn order(x: anytype, y: @TypeOf(x)) i32 {
    return if (x < y) -1 else if (x > y) 1 else 0;
}

inline fn memOrder(a: []const u8, b: []const u8) i32 {
    const m = @min(a.len, b.len);
    switch (std.mem.order(u8, a[0..m], b[0..m])) {
        .lt => return -1,
        .gt => return 1,
        .eq => return order(a.len, b.len),
    }
}

fn cmpNumText(a: []const u8, b: []const u8) i32 {
    const x = parseNum(a);
    const y = parseNum(b);
    if (x.neg != y.neg) return if (x.neg) -1 else 1;
    var d: i32 = order(x.int.len, y.int.len);
    if (d == 0) d = memOrder(x.int, y.int);
    if (d == 0) d = memOrder(x.frac, y.frac);
    return if (x.neg) -d else d;
}

fn foldByte(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn cmpFold(a: []const u8, b: []const u8) i32 {
    const m = @min(a.len, b.len);
    for (a[0..m], b[0..m]) |x, y| {
        const fx = foldByte(x);
        const fy = foldByte(y);
        if (fx != fy) return if (fx < fy) -1 else 1;
    }
    return order(a.len, b.len);
}

const Span = struct {
    p: [*]const u8,
    len: usize,
    num: i64,
    fast: bool,
};

const Line = struct {
    ptr: [*]const u8,
    len: usize,
    pre: u64,
    idx: usize,

    inline fn bytes(self: Line) []const u8 {
        return self.ptr[0..self.len];
    }
};

fn prefixOf(b: []const u8) u64 {
    if (b.len >= 8) return std.mem.readInt(u64, b[0..8], .big);
    var tmp: [8]u8 = @splat(0);
    @memcpy(tmp[0..b.len], b);
    return std.mem.readInt(u64, &tmp, .big);
}

inline fn plainOrder(a: Line, b: Line) i32 {
    if (a.pre != b.pre) return if (a.pre < b.pre) -1 else 1;
    if (a.len <= 8 or b.len <= 8) return order(a.len, b.len);
    return memOrder(a.ptr[8..a.len], b.ptr[8..b.len]);
}

const PlainCmp = struct {
    fn lt(_: void, a: Line, b: Line) bool {
        return plainOrder(a, b) < 0;
    }
    fn gt(_: void, a: Line, b: Line) bool {
        return plainOrder(a, b) > 0;
    }
};

const KeyCmp = struct {
    keys: []const Key,
    spans: []const Span,
    reverse: bool,
    tie_keys_only: bool,

    fn keyOrder(self: *const KeyCmp, a: Line, b: Line) i32 {
        const nk = self.keys.len;
        const sa = self.spans[a.idx * nk ..][0..nk];
        const sb = self.spans[b.idx * nk ..][0..nk];
        for (self.keys, sa, sb) |k, x, y| {
            var d: i32 = undefined;
            if (k.numeric) {
                d = if (x.fast and y.fast) order(x.num, y.num) else cmpNumText(x.p[0..x.len], y.p[0..y.len]);
            } else if (k.fold) {
                d = cmpFold(x.p[0..x.len], y.p[0..y.len]);
            } else {
                d = memOrder(x.p[0..x.len], y.p[0..y.len]);
            }
            if (d != 0) return if (k.reverse) -d else d;
        }
        return 0;
    }

    fn full(self: *const KeyCmp, a: Line, b: Line) i32 {
        const d = self.keyOrder(a, b);
        if (d != 0 or self.tie_keys_only) return d;
        const e = memOrder(a.bytes(), b.bytes());
        return if (self.reverse) -e else e;
    }

    fn lt(self: *const KeyCmp, a: Line, b: Line) bool {
        const d = self.full(a, b);
        if (d != 0) return d < 0;
        return a.idx < b.idx;
    }
};

fn buildSpans(spans: []Span, lines: []const Line, keys: []const Key, tab: ?u8) void {
    const nk = keys.len;
    for (lines, 0..) |ln, i| {
        const text = ln.bytes();
        for (keys, 0..) |k, j| {
            const beg = begField(text, k, tab);
            const lim = @max(beg, limField(text, k, tab));
            var s: Span = .{ .p = text.ptr + beg, .len = lim - beg, .num = 0, .fast = false };
            if (k.numeric) {
                const n = parseNum(text[beg..lim]);
                if (n.int.len <= 18 and n.frac.len == 0) {
                    var v: i64 = 0;
                    for (n.int) |c| v = v * 10 + (c - '0');
                    s.num = if (n.neg) -v else v;
                    s.fast = true;
                }
            }
            spans[i * nk + j] = s;
        }
    }
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, prog, io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const alloc = ctx.alloc;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);
    const cfg = (try parseArgs(argv, io.err, &files, alloc)) orelse return 2;
    if (files.items.len == 0) try files.append(alloc, "-");
    const delim: u8 = if (cfg.zero) 0 else '\n';

    if (cfg.check == .off) {
        for (files.items) |name| {
            if (common.isDashOperand(name)) continue;
            var pb: [common.path_max]u8 = undefined;
            const full = common.joinCwd(&pb, ctx.cwd, name) catch {
                common.fileErrReason(ctx, io, prog, "cannot read: ", name, false, "", "File name too long");
                return 2;
            };
            Io.Dir.cwd().access(ctx.io, full, .{ .read = true }) catch |e| {
                common.fileErrReason(ctx, io, prog, "cannot read: ", name, false, "", common.errnoText(e));
                return 2;
            };
        }
    }
    if (cfg.output) |path| {
        var pb: [common.path_max]u8 = undefined;
        const full = common.joinCwd(&pb, ctx.cwd, path) catch {
            common.fileErrReason(ctx, io, prog, "open failed: ", path, false, "", "File name too long");
            return 2;
        };
        const f = Io.Dir.cwd().createFile(ctx.io, full, .{ .truncate = false }) catch |e| {
            common.fileErrReason(ctx, io, prog, "open failed: ", path, false, "", common.errnoText(e));
            return 2;
        };
        f.close(ctx.io);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (files.items) |name| {
        var in: common.Input = .{};
        in.open(ctx, io, name) catch |e| {
            common.fileErrReason(ctx, io, prog, if (cfg.check != .off) "open failed: " else "cannot read: ", name, false, "", common.errnoText(e));
            return 2;
        };
        defer in.close();
        if (!in.stdin and in.src.kind == .file) try buf.ensureUnusedCapacity(alloc, in.src.size + 1);
        const start = buf.items.len;
        while (true) {
            const chunk = (common.nextChunk(in.r) catch {
                common.fileErrReason(ctx, io, prog, "read failed: ", name, false, "", in.readErr());
                return 2;
            }) orelse break;
            try buf.appendSlice(alloc, chunk);
        }
        if (buf.items.len > start and buf.items[buf.items.len - 1] != delim) try buf.append(alloc, delim);
    }

    const data = buf.items;
    const n = common.countByte(data, delim);
    const lines = try alloc.alloc(Line, n);
    defer alloc.free(lines);
    {
        var pos: usize = 0;
        var i: usize = 0;
        while (pos < data.len) : (i += 1) {
            const e = std.mem.findScalarPos(u8, data, pos, delim).?;
            const text = data[pos..e];
            lines[i] = .{ .ptr = text.ptr, .len = text.len, .pre = if (cfg.nkeys == 0) prefixOf(text) else 0, .idx = i };
            pos = e + 1;
        }
    }

    const keys = cfg.keys[0..cfg.nkeys];
    var spans: []Span = &.{};
    defer if (spans.len > 0) alloc.free(spans);
    var kc: KeyCmp = .{ .keys = keys, .spans = spans, .reverse = cfg.g_r, .tie_keys_only = cfg.unique or cfg.stable };
    if (keys.len > 0) {
        spans = try alloc.alloc(Span, n * keys.len);
        buildSpans(spans, lines, keys, cfg.tab);
        kc.spans = spans;
    }

    if (cfg.check != .off) return checkOrder(ctx, io, cfg, files.items[0], lines, &kc);

    if (keys.len == 0) {
        if (cfg.g_r) std.sort.pdq(Line, lines, {}, PlainCmp.gt) else std.sort.pdq(Line, lines, {}, PlainCmp.lt);
    } else {
        std.sort.pdq(Line, lines, &kc, KeyCmp.lt);
    }

    if (cfg.output) |path| {
        var pb: [common.path_max]u8 = undefined;
        const full = common.joinCwd(&pb, ctx.cwd, path) catch {
            common.fileErrReason(ctx, io, prog, "open failed: ", path, false, "", "File name too long");
            return 2;
        };
        const f = Io.Dir.cwd().createFile(ctx.io, full, .{}) catch |e| {
            common.fileErrReason(ctx, io, prog, "open failed: ", path, false, "", common.errnoText(e));
            return 2;
        };
        defer f.close(ctx.io);
        const wbuf = try alloc.alloc(u8, 65536);
        defer alloc.free(wbuf);
        var fw = f.writerStreaming(ctx.io, wbuf);
        emit(&fw.interface, lines, delim, cfg.unique, &kc, keys.len == 0) catch {
            common.fileErrReason(ctx, io, prog, "write failed: ", path, false, "", "Input/output error");
            return 2;
        };
        fw.interface.flush() catch {
            common.fileErrReason(ctx, io, prog, "write failed: ", path, false, "", "Input/output error");
            return 2;
        };
        return 0;
    }
    try emit(io.out, lines, delim, cfg.unique, &kc, keys.len == 0);
    return 0;
}

fn emit(w: *Io.Writer, lines: []const Line, delim: u8, unique: bool, kc: *const KeyCmp, plain: bool) Io.Writer.Error!void {
    var saved: ?Line = null;
    for (lines) |ln| {
        if (unique) {
            if (saved) |s| {
                const same = if (plain) (s.len == ln.len and std.mem.eql(u8, s.bytes(), ln.bytes())) else kc.keyOrder(s, ln) == 0;
                if (same) continue;
            }
            saved = ln;
        }
        try common.put(w, ln.bytes());
        try common.putByte(w, delim);
    }
}

fn checkOrder(ctx: *Ctx, io: Stdio, cfg: Config, name: []const u8, lines: []const Line, kc: *const KeyCmp) u8 {
    if (lines.len < 2) return 0;
    for (lines[1..], 1..) |ln, i| {
        const prev = lines[i - 1];
        const d: i32 = if (cfg.nkeys == 0) plainOrder(prev, ln) * (if (cfg.g_r) @as(i32, -1) else 1) else kc.full(prev, ln);
        const bad = if (cfg.unique) d >= 0 else d > 0;
        if (!bad) continue;
        if (cfg.check == .diag) {
            const w = io.err;
            w.writeAll(prog) catch {};
            w.writeAll(": ") catch {};
            common.writeQuoted(w, name, false, common.isUtf8Locale(ctx.env)) catch {};
            w.print(":{d}: disorder: ", .{i + 1}) catch {};
            w.writeAll(ln.bytes()) catch {};
            w.writeByte('\n') catch {};
            w.flush() catch {};
        }
        return 1;
    }
    return 0;
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "sort plain" {
    try t(&.{"sort"}, "b\na\nc\n", "a\nb\nc\n");
    try t(&.{"sort"}, "b\na\nc", "a\nb\nc\n");
    try t(&.{ "sort", "-r" }, "b\na\nc\n", "c\nb\na\n");
    try t(&.{ "sort", "-u" }, "b\na\nb\n", "a\nb\n");
    try t(&.{"sort"}, "", "");
    try t(&.{"sort"}, "abcdefghij\nabcdefghi\nabcdefgh\nabcdefghijk\n", "abcdefgh\nabcdefghi\nabcdefghij\nabcdefghijk\n");
}

test "sort keys" {
    try t(&.{ "sort", "-n" }, "10\n9\n-1\n1.5\n", "-1\n1.5\n9\n10\n");
    try t(&.{ "sort", "-t:", "-k2,2n" }, "a:10\nb:9\n", "b:9\na:10\n");
    try t(&.{ "sort", "-k2" }, "x b\ny a\n", "y a\nx b\n");
    try t(&.{ "sort", "-f" }, "b\nA\na\n", "A\na\nb\n");
    try t(&.{ "sort", "-s", "-k1,1" }, "b 2\na 1\nb 1\n", "a 1\nb 2\nb 1\n");
    try t(&.{ "sort", "-z" }, "b\x00a\x00", "a\x00b\x00");
}

test "sort supports" {
    try std.testing.expect(supports(&.{ "sort", "-k2,2nr", "f" }));
    try std.testing.expect(supports(&.{ "sort", "-t", ",", "-k3.2,4b", "-u" }));
    try std.testing.expect(!supports(&.{ "sort", "-h" }));
    try std.testing.expect(!supports(&.{ "sort", "-V" }));
    try std.testing.expect(!supports(&.{ "sort", "-k0" }));
    try std.testing.expect(!supports(&.{ "sort", "-t", "ab" }));
    try std.testing.expect(!supports(&.{ "sort", "-c", "a", "b" }));
    try std.testing.expect(!supports(&.{ "sort", "-m" }));
}

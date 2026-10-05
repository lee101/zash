const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const prog = "uniq";

const specs = [_]common.OptSpec{
    .{ .id = 'c', .short = 'c', .long = "count" },
    .{ .id = 'd', .short = 'd', .long = "repeated" },
    .{ .id = 'u', .short = 'u', .long = "unique" },
    .{ .id = 'i', .short = 'i', .long = "ignore-case" },
    .{ .id = 'z', .short = 'z', .long = "zero-terminated" },
    .{ .id = 'f', .short = 'f', .long = "skip-fields", .arg = .required },
    .{ .id = 's', .short = 's', .long = "skip-chars", .arg = .required },
    .{ .id = 'w', .short = 'w', .long = "check-chars", .arg = .required },
};

const Config = struct {
    count: bool = false,
    dups: bool = false,
    uniq: bool = false,
    icase: bool = false,
    zero: bool = false,
    skip_f: usize = 0,
    skip_s: usize = 0,
    check: usize = std.math.maxInt(usize),
    nfiles: usize = 0,
    in: ?[]const u8 = null,
    out: ?[]const u8 = null,
};

fn parseCount(s: []const u8) ?usize {
    if (s.len == 0 or s.len > 18) return null;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn parseArgs(argv: []const []const u8, err: ?*Io.Writer) ?Config {
    var cfg: Config = .{};
    var p = common.Parser.init(argv, &specs, err);
    while (true) {
        const it = (p.next() catch return null) orelse break;
        switch (it) {
            .operand => |o| {
                if (o.len > 1 and o[0] == '+') return null;
                switch (cfg.nfiles) {
                    0 => cfg.in = o,
                    1 => cfg.out = o,
                    else => return null,
                }
                cfg.nfiles += 1;
            },
            .opt => |m| switch (m.id) {
                'c' => cfg.count = true,
                'd' => cfg.dups = true,
                'u' => cfg.uniq = true,
                'i' => cfg.icase = true,
                'z' => cfg.zero = true,
                'f' => cfg.skip_f = parseCount(m.arg.?) orelse return null,
                's' => cfg.skip_s = parseCount(m.arg.?) orelse return null,
                'w' => cfg.check = parseCount(m.arg.?) orelse return null,
                else => unreachable,
            },
        }
    }
    if (cfg.dups and cfg.uniq) return null;
    return cfg;
}

pub fn supports(argv: []const []const u8) bool {
    return parseArgs(argv, null) != null;
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    if (common.ctypeKind(env) != .other) return true;
    const cfg = parseArgs(argv, null) orelse return false;
    return !cfg.icase and cfg.skip_f == 0;
}

inline fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn fieldOff(line: []const u8, cfg: *const Config) usize {
    var i: usize = 0;
    const size = line.len;
    var n: usize = 0;
    while (n < cfg.skip_f and i < size) : (n += 1) {
        while (i < size and isBlank(line[i])) i += 1;
        while (i < size and !isBlank(line[i])) i += 1;
    }
    return i + @min(cfg.skip_s, size - i);
}

fn foldByte(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn differ(a: []const u8, b: []const u8, cfg: *const Config) bool {
    var x = a[fieldOff(a, cfg)..];
    var y = b[fieldOff(b, cfg)..];
    if (cfg.check < x.len) x = x[0..cfg.check];
    if (cfg.check < y.len) y = y[0..cfg.check];
    if (x.len != y.len) return true;
    if (!cfg.icase) return !std.mem.eql(u8, x, y);
    for (x, y) |p, q| if (foldByte(p) != foldByte(q)) return true;
    return false;
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, prog, io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const alloc = ctx.alloc;
    const cfg = parseArgs(argv, io.err) orelse return 1;
    const name = cfg.in orelse "-";
    var in: common.Input = .{};
    in.open(ctx, io, name) catch |e| {
        common.fileErrReason(ctx, io, prog, "", name, false, "", common.errnoText(e));
        return 1;
    };
    defer in.close();

    var out_file: ?Io.File = null;
    var fw: Io.File.Writer = undefined;
    var wbuf: []u8 = &.{};
    defer if (wbuf.len > 0) alloc.free(wbuf);
    var w = io.out;
    if (cfg.out) |path| {
        if (!common.isDashOperand(path)) {
            var pb: [common.path_max]u8 = undefined;
            const full = common.joinCwd(&pb, ctx.cwd, path) catch {
                common.fileErrReason(ctx, io, prog, "", path, false, "", "File name too long");
                return 1;
            };
            const f = Io.Dir.cwd().createFile(ctx.io, full, .{}) catch |e| {
                common.fileErrReason(ctx, io, prog, "", path, false, "", common.errnoText(e));
                return 1;
            };
            out_file = f;
            wbuf = try alloc.alloc(u8, 65536);
            fw = f.writerStreaming(ctx.io, wbuf);
            w = &fw.interface;
        }
    }
    defer if (out_file) |f| f.close(ctx.io);

    const delim: u8 = if (cfg.zero) 0 else '\n';
    const emit_uniq = !cfg.dups;
    const emit_dup = !cfg.uniq;
    const immediate = !cfg.count and emit_uniq and emit_dup;

    var lr = common.LineReader.init(alloc, in.r, delim);
    defer lr.deinit();
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(alloc);
    var have = false;
    var count: u64 = 0;

    while (lr.next() catch {
        common.errRaw(io, "uniq: error reading '{s}'\n", .{name});
        return 1;
    }) |line| {
        if (have and !differ(prev.items, line.bytes, &cfg)) {
            count += 1;
            continue;
        }
        if (have and !immediate) try flushGroup(w, prev.items, count, &cfg, delim, emit_uniq, emit_dup);
        prev.clearRetainingCapacity();
        try prev.appendSlice(alloc, line.bytes);
        have = true;
        count = 1;
        if (immediate) {
            try common.put(w, line.bytes);
            try common.putByte(w, delim);
        }
    }
    if (have and !immediate) try flushGroup(w, prev.items, count, &cfg, delim, emit_uniq, emit_dup);
    if (out_file != null) {
        w.flush() catch {
            common.errFmt(io, prog, "write error", .{});
            return 1;
        };
    }
    return 0;
}

fn flushGroup(w: *Io.Writer, line: []const u8, count: u64, cfg: *const Config, delim: u8, emit_uniq: bool, emit_dup: bool) Io.Writer.Error!void {
    if (count == 1) {
        if (!emit_uniq) return;
    } else if (!emit_dup) return;
    if (cfg.count) {
        try common.putUintPad(w, count, 7);
        try common.putByte(w, ' ');
    }
    try common.put(w, line);
    try common.putByte(w, delim);
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "uniq" {
    try t(&.{"uniq"}, "a\na\nb\na\n", "a\nb\na\n");
    try t(&.{"uniq"}, "a\na\nb", "a\nb\n");
    try t(&.{ "uniq", "-c" }, "a\na\nb\n", "      2 a\n      1 b\n");
    try t(&.{ "uniq", "-d" }, "a\na\nb\n", "a\n");
    try t(&.{ "uniq", "-u" }, "a\na\nb\n", "b\n");
    try t(&.{ "uniq", "-i" }, "a\nA\nb\n", "a\nb\n");
    try t(&.{ "uniq", "-f1" }, "x a\ny a\nz b\n", "x a\nz b\n");
    try t(&.{ "uniq", "-s1", "-w1" }, "xa1\nya2\nzb\n", "xa1\nzb\n");
}

test "uniq supports" {
    try std.testing.expect(supports(&.{ "uniq", "-c", "f" }));
    try std.testing.expect(!supports(&.{ "uniq", "-D" }));
    try std.testing.expect(!supports(&.{ "uniq", "-d", "-u" }));
    try std.testing.expect(!supports(&.{ "uniq", "-f", "x" }));
    try std.testing.expect(!supports(&.{ "uniq", "a", "b", "c" }));
}

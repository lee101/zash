const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const specs = [_]common.OptSpec{
    .{ .id = 'n', .short = 'n', .long = "lines", .arg = .required },
    .{ .id = 'c', .short = 'c', .long = "bytes", .arg = .required },
    .{ .id = 'q', .short = 'q', .long = "quiet" },
    .{ .id = 'q', .long = "silent" },
    .{ .id = 'v', .short = 'v', .long = "verbose" },
    .{ .id = 'z', .short = 'z', .long = "zero-terminated" },
};

const Headers = enum { auto, never, always };

const Count = struct { n: u64, elide: bool };

fn parseCount(arg: []const u8) ?Count {
    var s = arg;
    var elide = false;
    if (s.len > 0 and s[0] == '-') {
        elide = true;
        s = s[1..];
    }
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len == 0 or s[0] < '0' or s[0] > '9') return null;
    const p = common.parseSize(s) orelse return null;
    if (p.overflow) return null;
    return .{ .n = p.value, .elide = elide };
}

fn isObsolete(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub fn supports(argv: []const []const u8) bool {
    var p = common.Parser.init(argv, &specs, null);
    if (argv.len > 1 and isObsolete(argv[1])) p.i = 2;
    while (p.next() catch return false) |it| switch (it) {
        .opt => |m| switch (m.id) {
            'n', 'c' => if (parseCount(m.arg.?) == null) return false,
            else => {},
        },
        .operand => |o| if (o.len > 1 and o[0] == '-' and o[1] >= '0' and o[1] <= '9') return false,
    };
    return true;
}

const Config = struct {
    bytes: bool = false,
    count: u64 = 10,
    elide: bool = false,
    delim: u8 = '\n',
    headers: Headers = .auto,
};

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog = argv[0];
    var cfg: Config = .{};
    var p = common.Parser.init(argv, &specs, io.err);
    if (argv.len > 1 and isObsolete(argv[1])) {
        cfg.count = common.parseSize(argv[1][1..]).?.value;
        p.i = 2;
    }
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.alloc);
    while (true) {
        const it = (p.next() catch return 1) orelse break;
        switch (it) {
            .operand => |o| try files.append(ctx.alloc, o),
            .opt => |m| switch (m.id) {
                'n', 'c' => {
                    cfg.bytes = m.id == 'c';
                    const c = parseCount(m.arg.?) orelse {
                        const q = common.quotes(ctx.env);
                        common.errFmt(io, prog, "invalid number of {s}: {s}{s}{s}", .{ if (cfg.bytes) "bytes" else "lines", q.l, m.arg.?, q.r });
                        return 1;
                    };
                    cfg.count = c.n;
                    cfg.elide = c.elide;
                },
                'q' => cfg.headers = .never,
                'v' => cfg.headers = .always,
                'z' => cfg.delim = 0,
                else => unreachable,
            },
        }
    }
    if (files.items.len == 0) try files.append(ctx.alloc, "-");
    const print_headers = switch (cfg.headers) {
        .never => false,
        .always => true,
        .auto => files.items.len > 1,
    };
    var status: u8 = 0;
    var first = true;
    for (files.items) |name| {
        var in: common.Input = .{};
        in.open(ctx, io, name) catch |e| {
            common.fileErrReason(ctx, io, prog, "cannot open ", name, true, " for reading", common.errnoText(e));
            status = 1;
            continue;
        };
        defer in.close();
        if (print_headers) {
            if (!first) try common.putByte(io.out, '\n');
            first = false;
            try common.put(io.out, "==> ");
            try common.put(io.out, if (in.stdin) "standard input" else name);
            try common.put(io.out, " <==\n");
        }
        headOne(ctx, in.r, io.out, cfg) catch |e| switch (e) {
            error.ReadFailed => {
                common.fileErrReason(ctx, io, prog, "error reading ", name, true, "", in.readErr());
                status = 1;
                continue;
            },
            else => |other| return other,
        };
    }
    return status;
}

fn headOne(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, cfg: Config) common.IoError!void {
    if (!cfg.elide) {
        if (cfg.bytes) return takeBytes(r, w, cfg.count);
        return takeLines(r, w, cfg.count, cfg.delim);
    }
    if (cfg.count == 0) return copyAll(r, w);
    if (cfg.bytes) return elideBytes(ctx, r, w, cfg.count);
    return elideLines(ctx, r, w, cfg.count, cfg.delim);
}

fn copyAll(r: *Io.Reader, w: *Io.Writer) common.IoError!void {
    while (try common.nextChunk(r)) |c| try common.put(w, c);
}

fn takeBytes(r: *Io.Reader, w: *Io.Writer, n: u64) common.IoError!void {
    var left = n;
    while (left > 0) {
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            continue;
        }
        const b = r.buffered();
        const k: usize = @intCast(@min(left, b.len));
        try common.put(w, b[0..k]);
        r.toss(k);
        left -= k;
    }
}

fn takeLines(r: *Io.Reader, w: *Io.Writer, n: u64, delim: u8) common.IoError!void {
    var left = n;
    while (left > 0) {
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            continue;
        }
        const b = r.buffered();
        const c = common.countByte(b, delim);
        if (c < left) {
            left -= c;
            try common.put(w, b);
            r.tossBuffered();
            continue;
        }
        var end: usize = 0;
        while (left > 0) {
            end = std.mem.findScalarPos(u8, b, end, delim).? + 1;
            left -= 1;
        }
        try common.put(w, b[0..end]);
        r.toss(end);
    }
}

fn elideLines(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, n: u64, delim: u8) common.IoError!void {
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(ctx.alloc);
    var start: usize = 0;
    var nl: u64 = 0;
    while (try common.nextChunk(r)) |c| {
        try p.appendSlice(ctx.alloc, c);
        nl += common.countByte(c, delim);
        if (nl > n) {
            var k = nl - n;
            var end = start;
            while (k > 0) : (k -= 1) end = std.mem.findScalarPos(u8, p.items, end, delim).? + 1;
            try common.put(w, p.items[start..end]);
            nl = n;
            start = end;
        }
        if (start > 65536 and start * 2 > p.items.len) {
            const rest = p.items.len - start;
            @memmove(p.items[0..rest], p.items[start..]);
            p.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
    const tail = p.items[start..];
    const partial = tail.len > 0 and tail[tail.len - 1] != delim;
    const lines = nl + @intFromBool(partial);
    if (lines > n and nl > 0) {
        const end = std.mem.findScalar(u8, tail, delim).? + 1;
        try common.put(w, tail[0..end]);
    }
}

fn elideBytes(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, n: u64) common.IoError!void {
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(ctx.alloc);
    var start: usize = 0;
    while (try common.nextChunk(r)) |c| {
        try p.appendSlice(ctx.alloc, c);
        const have = p.items.len - start;
        if (have > n) {
            const emit: usize = @intCast(have - n);
            try common.put(w, p.items[start..][0..emit]);
            start += emit;
        }
        if (start > 65536 and start * 2 > p.items.len) {
            const rest = p.items.len - start;
            @memmove(p.items[0..rest], p.items[start..]);
            p.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8, status: u8) !void {
    return common.expectRun(run, argv, input, want, status);
}

test "head default ten lines" {
    var buf: [64]u8 = undefined;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var want: Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    for (0..15) |i| {
        try aw.writer.print("line{d}\n", .{i});
        if (i < 10) try want.writer.print("line{d}\n", .{i});
    }
    _ = &buf;
    try t(&.{"head"}, aw.writer.buffered(), want.writer.buffered(), 0);
}

test "head n and c" {
    try t(&.{ "head", "-n", "2" }, "a\nb\nc\n", "a\nb\n", 0);
    try t(&.{ "head", "-n2" }, "a\nb\nc\n", "a\nb\n", 0);
    try t(&.{ "head", "-2" }, "a\nb\nc\n", "a\nb\n", 0);
    try t(&.{ "head", "--lines=1" }, "a\nb\nc", "a\n", 0);
    try t(&.{ "head", "-n", "5" }, "a\nb", "a\nb", 0);
    try t(&.{ "head", "-n", "0" }, "a\nb", "", 0);
    try t(&.{ "head", "-c", "3" }, "abcdef", "abc", 0);
    try t(&.{ "head", "-c", "1K" }, "abcdef", "abcdef", 0);
    try t(&.{ "head", "-c", "0" }, "abcdef", "", 0);
    try t(&.{ "head", "-z", "-n", "1" }, "a\x00b\x00", "a\x00", 0);
}

test "head negative counts" {
    try t(&.{ "head", "-n", "-1" }, "a\nb\nc\n", "a\nb\n", 0);
    try t(&.{ "head", "-n", "-1" }, "a\nb\nc", "a\nb\n", 0);
    try t(&.{ "head", "-n", "-2" }, "a\nb\nc\n", "a\n", 0);
    try t(&.{ "head", "-n", "-3" }, "a\nb\nc\n", "", 0);
    try t(&.{ "head", "-n", "-5" }, "a\nb\nc\n", "", 0);
    try t(&.{ "head", "-n", "-0" }, "a\nb\nc", "a\nb\nc", 0);
    try t(&.{ "head", "-n", "-1" }, "abc", "", 0);
    try t(&.{ "head", "-c", "-2" }, "abcdef", "abcd", 0);
    try t(&.{ "head", "-c", "-9" }, "abcdef", "", 0);
}

test "head errors and supports" {
    try t(&.{ "head", "-n", "x" }, "", "", 1);
    try std.testing.expect(supports(&.{ "head", "-n", "5", "f" }));
    try std.testing.expect(supports(&.{ "head", "-5" }));
    try std.testing.expect(supports(&.{ "head", "-n-3", "-q" }));
    try std.testing.expect(!supports(&.{ "head", "--help" }));
    try std.testing.expect(!supports(&.{ "head", "f", "-5" }));
    try std.testing.expect(!supports(&.{ "head", "-n", "z" }));
    try std.testing.expect(!supports(&.{ "head", "-x" }));
}

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

const Count = struct { n: u64, from_start: bool };

fn parseCount(arg: []const u8) ?Count {
    var s = arg;
    var from_start = false;
    if (s.len > 0 and s[0] == '+') {
        from_start = true;
        s = s[1..];
    } else if (s.len > 0 and s[0] == '-') {
        s = s[1..];
    }
    if (s.len == 0 or s[0] < '0' or s[0] > '9') return null;
    const p = common.parseSize(s) orelse return null;
    if (p.overflow) return null;
    return .{ .n = p.value, .from_start = from_start };
}

fn isObsolete(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    const a = argv[1];
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| if (c < '0' or c > '9') return false;
    const argc = argv.len;
    if (argc == 2) return true;
    if (argc == 3 and !(argv[2].len > 1 and argv[2][0] == '-')) return true;
    if (argc >= 3 and argc <= 4 and std.mem.eql(u8, argv[2], "--")) return true;
    return false;
}

pub fn supports(argv: []const []const u8) bool {
    var p = common.Parser.init(argv, &specs, null);
    if (isObsolete(argv)) {
        if (common.parseSize(argv[1][1..]).?.overflow) return false;
        p.i = 2;
    }
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
    from_start: bool = false,
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
    if (isObsolete(argv)) {
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
                    cfg.from_start = c.from_start;
                },
                'q' => cfg.headers = .never,
                'v' => cfg.headers = .always,
                'z' => cfg.delim = 0,
                else => unreachable,
            },
        }
    }
    if (cfg.from_start and cfg.count > 0) cfg.count -= 1;
    if (cfg.count == 0 and !cfg.from_start) return 0;
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
        const shown: []const u8 = if (in.stdin) "standard input" else name;
        if (print_headers) {
            if (!first) try common.putByte(io.out, '\n');
            first = false;
            try common.put(io.out, "==> ");
            try common.put(io.out, shown);
            try common.put(io.out, " <==\n");
        }
        tailOne(ctx, &in, io.out, cfg) catch |e| switch (e) {
            error.ReadFatal => {
                common.fileErrReason(ctx, io, prog, "error reading ", shown, true, "", in.readErr());
                return 1;
            },
            error.ReadFailed => {
                common.fileErrReason(ctx, io, prog, "error reading ", shown, true, "", in.readErr());
                status = 1;
                continue;
            },
            else => |other| return other,
        };
    }
    return status;
}

fn tailOne(ctx: *Ctx, in: *common.Input, w: *Io.Writer, cfg: Config) (common.IoError || error{ReadFatal})!void {
    const seekable = !in.stdin and in.src.kind == .file and in.src.size > 0;
    if (cfg.from_start) {
        if (cfg.bytes) {
            if (seekable) {
                in.src.fr.seekTo(cfg.count) catch return error.ReadFailed;
            } else try skipBytes(in.r, cfg.count);
            return copyAll(in.r, w);
        }
        return fromLine(in.r, w, cfg.count, cfg.delim);
    }
    if (seekable) return lastFromFile(ctx, in, w, cfg);
    if (cfg.bytes) return lastBytesStream(ctx, in.r, w, cfg.count) catch |e| switch (e) {
        error.ReadFailed => error.ReadFatal,
        else => |other| other,
    };
    return lastLinesStream(ctx, in.r, w, cfg.count, cfg.delim);
}

fn copyAll(r: *Io.Reader, w: *Io.Writer) common.IoError!void {
    while (try common.nextChunk(r)) |c| try common.put(w, c);
}

fn skipBytes(r: *Io.Reader, n: u64) common.IoError!void {
    var left = n;
    while (left > 0) {
        if (r.bufferedLen() == 0) {
            r.fillMore() catch |e| switch (e) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            continue;
        }
        const k: usize = @intCast(@min(left, r.bufferedLen()));
        r.toss(k);
        left -= k;
    }
}

fn fromLine(r: *Io.Reader, w: *Io.Writer, skip: u64, delim: u8) common.IoError!void {
    var left = skip;
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
            r.tossBuffered();
            continue;
        }
        var end: usize = 0;
        while (left > 0) {
            end = std.mem.findScalarPos(u8, b, end, delim).? + 1;
            left -= 1;
        }
        r.toss(end);
    }
    return copyAll(r, w);
}

fn lastFromFile(ctx: *Ctx, in: *common.Input, w: *Io.Writer, cfg: Config) common.IoError!void {
    const size = in.src.size;
    var start: u64 = 0;
    if (cfg.bytes) {
        start = size -| cfg.count;
    } else {
        const cap: usize = @intCast(@min(size, 65536));
        const scratch = try ctx.alloc.alloc(u8, cap);
        defer ctx.alloc.free(scratch);
        var n = cfg.count;
        var pos = size;
        var first_chunk = true;
        scan: while (pos > 0) {
            const len: usize = @intCast(@min(pos, cap));
            const off = pos - len;
            var got: usize = 0;
            while (got < len) {
                const k = in.src.file.readPositional(ctx.io, &.{scratch[got..len]}, off + got) catch return error.ReadFailed;
                if (k == 0) return error.ReadFailed;
                got += k;
            }
            const buf = scratch[0..len];
            var end = len;
            if (first_chunk) {
                first_chunk = false;
                if (buf[len - 1] != cfg.delim) n -= 1;
            }
            while (common.findLastByte(buf[0..end], cfg.delim)) |i| {
                if (n == 0) {
                    start = off + i + 1;
                    break :scan;
                }
                n -= 1;
                end = i;
            }
            pos = off;
        }
    }
    in.src.fr.seekTo(start) catch return error.ReadFailed;
    return copyAll(in.r, w);
}

fn lastBytesStream(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, n: u64) common.IoError!void {
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(ctx.alloc);
    var start: usize = 0;
    while (try common.nextChunk(r)) |c| {
        try p.appendSlice(ctx.alloc, c);
        const have = p.items.len - start;
        if (have > n) start += @intCast(have - n);
        if (start > 65536 and start * 2 > p.items.len) {
            const rest = p.items.len - start;
            @memmove(p.items[0..rest], p.items[start..]);
            p.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
    try common.put(w, p.items[start..]);
}

fn lastLinesStream(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, n: u64, delim: u8) common.IoError!void {
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(ctx.alloc);
    var start: usize = 0;
    var nl: u64 = 0;
    while (try common.nextChunk(r)) |c| {
        try p.appendSlice(ctx.alloc, c);
        nl += common.countByte(c, delim);
        const partial: u64 = @intFromBool(p.items[p.items.len - 1] != delim);
        const lines = nl + partial;
        if (lines > n) {
            var k = lines - n;
            var end = start;
            while (k > 0) : (k -= 1) end = std.mem.findScalarPos(u8, p.items, end, delim).? + 1;
            nl -= lines - n;
            start = end;
        }
        if (start > 65536 and start * 2 > p.items.len) {
            const rest = p.items.len - start;
            @memmove(p.items[0..rest], p.items[start..]);
            p.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
    try common.put(w, p.items[start..]);
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8, status: u8) !void {
    return common.expectRun(run, argv, input, want, status);
}

test "tail streams" {
    try t(&.{ "tail", "-n", "2" }, "a\nb\nc\nd\n", "c\nd\n", 0);
    try t(&.{ "tail", "-n", "2" }, "a\nb\nc\nd", "c\nd", 0);
    try t(&.{ "tail", "-n", "1" }, "a\nb\nc\nd", "d", 0);
    try t(&.{ "tail", "-n", "9" }, "a\nb", "a\nb", 0);
    try t(&.{ "tail", "-n", "0" }, "a\nb", "", 0);
    try t(&.{ "tail", "-2" }, "a\nb\nc\n", "b\nc\n", 0);
    try t(&.{ "tail", "-n", "+2" }, "a\nb\nc\n", "b\nc\n", 0);
    try t(&.{ "tail", "-n", "+1" }, "a\nb\nc\n", "a\nb\nc\n", 0);
    try t(&.{ "tail", "-n", "+0" }, "a\nb\nc\n", "a\nb\nc\n", 0);
    try t(&.{ "tail", "-n", "+9" }, "a\nb\nc\n", "", 0);
    try t(&.{ "tail", "-c", "3" }, "abcdef", "def", 0);
    try t(&.{ "tail", "-c", "+3" }, "abcdef", "cdef", 0);
    try t(&.{ "tail", "-c", "10" }, "abcdef", "abcdef", 0);
    try t(&.{ "tail", "-z", "-n", "1" }, "a\x00b\x00", "b\x00", 0);
}

test "tail supports" {
    try std.testing.expect(supports(&.{ "tail", "-n", "5", "f" }));
    try std.testing.expect(supports(&.{ "tail", "-5" }));
    try std.testing.expect(supports(&.{ "tail", "-5", "f" }));
    try std.testing.expect(!supports(&.{ "tail", "-5", "-q", "f", "g" }));
    try std.testing.expect(!supports(&.{ "tail", "-f", "f" }));
    try std.testing.expect(!supports(&.{ "tail", "-F", "f" }));
    try std.testing.expect(supports(&.{ "tail", "-n", "+5", "f" }));
}

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const specs = [_]common.OptSpec{
    .{ .id = 'b', .short = 'b', .long = "bytes", .arg = .required },
    .{ .id = 'c', .short = 'c', .long = "characters", .arg = .required },
    .{ .id = 'f', .short = 'f', .long = "fields", .arg = .required },
    .{ .id = 'd', .short = 'd', .long = "delimiter", .arg = .required },
    .{ .id = 's', .short = 's', .long = "only-delimited" },
    .{ .id = 'n', .short = 'n' },
    .{ .id = 'z', .short = 'z', .long = "zero-terminated" },
    .{ .id = 'C', .long = "complement" },
    .{ .id = 'O', .long = "output-delimiter", .arg = .required },
};

const Range = struct { lo: u64, hi: u64 };
const open_end = std.math.maxInt(u64);

fn parseList(alloc: std.mem.Allocator, s: []const u8) !?[]Range {
    var list: std.ArrayList(Range) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| {
        if (tok.len == 0) return null;
        const dash = std.mem.findScalar(u8, tok, '-');
        var lo: u64 = 1;
        var hi: u64 = open_end;
        if (dash) |d| {
            const a = tok[0..d];
            const b = tok[d + 1 ..];
            if (a.len == 0 and b.len == 0) return null;
            if (a.len > 0) lo = parseNum(a) orelse return null;
            if (b.len > 0) hi = parseNum(b) orelse return null;
            if (lo == 0 or hi == 0) return null;
            if (hi < lo) return null;
        } else {
            lo = parseNum(tok) orelse return null;
            if (lo == 0) return null;
            hi = lo;
        }
        try list.append(alloc, .{ .lo = lo, .hi = hi });
    }
    std.mem.sort(Range, list.items, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi);
        }
    }.lt);
    var w: usize = 0;
    for (list.items) |r| {
        if (w > 0 and r.lo <= list.items[w - 1].hi) {
            if (r.hi > list.items[w - 1].hi) list.items[w - 1].hi = r.hi;
        } else {
            list.items[w] = r;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
    return try list.toOwnedSlice(alloc);
}

fn parseNum(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 18) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn complement(alloc: std.mem.Allocator, ranges: []const Range) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(alloc);
    var c: u64 = 1;
    for (ranges) |r| {
        if (c < r.lo) try out.append(alloc, .{ .lo = c, .hi = r.lo - 1 });
        if (r.hi == open_end) return try out.toOwnedSlice(alloc);
        c = r.hi + 1;
    }
    try out.append(alloc, .{ .lo = c, .hi = open_end });
    return try out.toOwnedSlice(alloc);
}

const Mode = enum { none, bytes, fields };

const Parsed = struct {
    mode: Mode = .none,
    list: []const u8 = "",
    delim: ?[]const u8 = null,
    only_delimited: bool = false,
    zero: bool = false,
    complement: bool = false,
    out_delim: ?[]const u8 = null,
    listopts: u8 = 0,
};

fn parseArgs(argv: []const []const u8, err: ?*Io.Writer, files: ?*std.ArrayList([]const u8), alloc: std.mem.Allocator) !?Parsed {
    var res: Parsed = .{};
    var p = common.Parser.init(argv, &specs, err);
    while (true) {
        const it = (p.next() catch return null) orelse break;
        switch (it) {
            .operand => |o| if (files) |f| try f.append(alloc, o),
            .opt => |m| switch (m.id) {
                'b', 'c' => {
                    res.mode = .bytes;
                    res.list = m.arg.?;
                    res.listopts += 1;
                },
                'f' => {
                    res.mode = .fields;
                    res.list = m.arg.?;
                    res.listopts += 1;
                },
                'd' => res.delim = m.arg.?,
                's' => res.only_delimited = true,
                'n' => {},
                'z' => res.zero = true,
                'C' => res.complement = true,
                'O' => res.out_delim = m.arg.?,
                else => unreachable,
            },
        }
    }
    return res;
}

pub fn supports(argv: []const []const u8) bool {
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const a = fba.allocator();
    const pr = (parseArgs(argv, null, null, a) catch return false) orelse return false;
    if (pr.listopts != 1) return false;
    if (pr.mode != .fields) {
        if (pr.delim != null or pr.only_delimited) return false;
    }
    if (pr.delim) |d| {
        if (d.len != 1 or d[0] == '\n' or d[0] == 0) return false;
    }
    const list = (parseList(a, pr.list) catch return false) orelse return false;
    _ = list;
    return true;
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog = argv[0];
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.alloc);
    const pr = (try parseArgs(argv, io.err, &files, ctx.alloc)) orelse return 1;
    if (pr.listopts == 0) {
        common.errRaw(io, "{s}: you must specify a list of bytes, characters, or fields\nTry '{s} --help' for more information.\n", .{ prog, prog });
        return 1;
    }
    if (pr.listopts > 1) {
        common.errRaw(io, "{s}: only one type of list may be specified\nTry '{s} --help' for more information.\n", .{ prog, prog });
        return 1;
    }
    const parsed_list = try parseList(ctx.alloc, pr.list);
    if (parsed_list == null) {
        common.errFmt(io, prog, "invalid field value", .{});
        return 1;
    }
    var ranges = parsed_list.?;
    defer ctx.alloc.free(ranges);
    if (pr.complement) {
        const c = try complement(ctx.alloc, ranges);
        ctx.alloc.free(ranges);
        ranges = c;
    }
    const od_norm: ?[]const u8 = if (pr.out_delim) |o| (if (o.len == 0) "\x00" else o) else null;
    const delim_char: u8 = if (pr.delim) |d| (if (d.len > 0) d[0] else 0) else '\t';
    const out_delim: []const u8 = od_norm orelse &[_]u8{delim_char};
    const line_delim: u8 = if (pr.zero) 0 else '\n';
    if (files.items.len == 0) try files.append(ctx.alloc, "-");
    var status: u8 = 0;
    for (files.items) |name| {
        var in: common.Input = .{};
        in.open(ctx, io, name) catch |e| {
            common.fileErrReason(ctx, io, prog, "", name, false, "", common.errnoText(e));
            status = 1;
            continue;
        };
        defer in.close();
        const res = switch (pr.mode) {
            .bytes => cutBytes(ctx, in.r, io.out, ranges, od_norm, line_delim),
            else => cutFields(ctx, in.r, io.out, ranges, delim_char, out_delim, pr.only_delimited, line_delim),
        };
        res catch |e| switch (e) {
            error.ReadFailed => {
                common.fileErrReason(ctx, io, prog, "", name, false, "", in.readErr());
                status = 1;
            },
            else => |other| return other,
        };
    }
    return status;
}

fn cutBytes(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, ranges: []const Range, out_delim: ?[]const u8, line_delim: u8) common.IoError!void {
    var lr = common.LineReader.init(ctx.alloc, r, line_delim);
    defer lr.deinit();
    while (try lr.next()) |line| {
        const b = line.bytes;
        var printed = false;
        for (ranges) |rg| {
            if (rg.lo > b.len) break;
            const s: usize = @intCast(rg.lo - 1);
            const e: usize = if (rg.hi >= b.len) b.len else @intCast(rg.hi);
            if (out_delim) |od| {
                if (printed) try common.put(w, od);
            }
            printed = true;
            try common.put(w, b[s..e]);
        }
        try common.putByte(w, line_delim);
    }
}

fn cutFields(ctx: *Ctx, r: *Io.Reader, w: *Io.Writer, ranges: []const Range, delim: u8, out_delim: []const u8, only_delimited: bool, line_delim: u8) common.IoError!void {
    var lr = common.LineReader.init(ctx.alloc, r, line_delim);
    defer lr.deinit();
    const last_hi: u64 = if (ranges.len > 0) ranges[ranges.len - 1].hi else 0;
    while (try lr.next()) |line| {
        const b = line.bytes;
        var d = std.mem.findScalar(u8, b, delim) orelse {
            if (!only_delimited) {
                try common.put(w, b);
                try common.putByte(w, line_delim);
            }
            continue;
        };
        var field: u64 = 1;
        var pos: usize = 0;
        var ri: usize = 0;
        var printed = false;
        while (true) {
            while (ri < ranges.len and ranges[ri].hi < field) ri += 1;
            if (ri >= ranges.len) break;
            if (field >= ranges[ri].lo) {
                if (printed) try common.put(w, out_delim);
                printed = true;
                try common.put(w, b[pos..d]);
            }
            if (field >= last_hi) break;
            pos = d + 1;
            field += 1;
            d = std.mem.findScalarPos(u8, b, pos, delim) orelse {
                while (ri < ranges.len and ranges[ri].hi < field) ri += 1;
                if (ri < ranges.len and field >= ranges[ri].lo) {
                    if (printed) try common.put(w, out_delim);
                    printed = true;
                    try common.put(w, b[pos..]);
                }
                break;
            };
        }
        try common.putByte(w, line_delim);
    }
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "cut bytes" {
    try t(&.{ "cut", "-b1-2,4" }, "abcdef\nxy\n", "abd\nxy\n");
    try t(&.{ "cut", "-c3-" }, "abcdef", "cdef\n");
    try t(&.{ "cut", "-b1-2,3-4", "--output-delimiter=X" }, "abcdef\n", "abXcd\n");
    try t(&.{ "cut", "-b2", "--complement" }, "abc\n", "ac\n");
}

test "cut fields" {
    try t(&.{ "cut", "-d:", "-f2" }, "a:b:c\nnodelim\n", "b\nnodelim\n");
    try t(&.{ "cut", "-d:", "-f2", "-s" }, "a:b:c\nnodelim\n", "b\n");
    try t(&.{ "cut", "-d:", "-f1,3" }, "a:b:c\n", "a:c\n");
    try t(&.{ "cut", "-d:", "-f3-" }, "a:b:c:d\n", "c:d\n");
    try t(&.{ "cut", "-d:", "-f5" }, "a:b:c\n", "\n");
    try t(&.{ "cut", "-d:", "-f1-2,3", "--output-delimiter=XY" }, "a:b:c\n", "aXYbXYc\n");
    try t(&.{ "cut", "-f2" }, "a\tb\n", "b\n");
}

test "cut supports" {
    try std.testing.expect(supports(&.{ "cut", "-d,", "-f1,3-5", "f" }));
    try std.testing.expect(!supports(&.{ "cut", "-f0" }));
    try std.testing.expect(!supports(&.{ "cut", "-f2-1" }));
    try std.testing.expect(!supports(&.{ "cut", "-b1", "-d," }));
    try std.testing.expect(!supports(&.{ "cut", "-d,", "-f1", "-f2" }));
    try std.testing.expect(!supports(&.{"cut"}));
    try std.testing.expect(!supports(&.{ "cut", "-d,,", "-f1" }));
}

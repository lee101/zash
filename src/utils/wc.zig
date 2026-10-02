const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const uni = @import("uni.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const specs = [_]common.OptSpec{
    .{ .id = 'l', .short = 'l', .long = "lines" },
    .{ .id = 'w', .short = 'w', .long = "words" },
    .{ .id = 'm', .short = 'm', .long = "chars" },
    .{ .id = 'c', .short = 'c', .long = "bytes" },
    .{ .id = 'L', .short = 'L', .long = "max-line-length" },
};

pub fn supports(argv: []const []const u8) bool {
    var p = common.Parser.init(argv, &specs, null);
    while (p.next() catch return false) |_| {}
    return true;
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    if (common.ctypeKind(env) != .other) return true;
    var p = common.Parser.init(argv, &specs, null);
    while (p.next() catch return false) |it| switch (it) {
        .opt => |m| switch (m.id) {
            'w', 'm', 'L' => return false,
            else => {},
        },
        .operand => {},
    };
    return true;
}

const Flags = struct {
    lines: bool = false,
    words: bool = false,
    chars: bool = false,
    bytes: bool = false,
    maxlen: bool = false,

    fn count(self: Flags) u32 {
        return @as(u32, @intFromBool(self.lines)) + @intFromBool(self.words) + @intFromBool(self.chars) + @intFromBool(self.bytes) + @intFromBool(self.maxlen);
    }
};

const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    chars: u64 = 0,
    bytes: u64 = 0,
    maxlen: u64 = 0,
};

const Counter = struct {
    flags: Flags,
    utf8: bool,
    c: Counts = .{},
    in_word: bool = false,
    pos: u64 = 0,
    carry: [3]u8 = undefined,
    carry_len: usize = 0,
    scratch: std.ArrayList(u8) = .empty,

    fn needScan(self: *const Counter) bool {
        return self.flags.words or self.flags.maxlen or (self.utf8 and self.flags.chars);
    }

    fn feed(self: *Counter, alloc: std.mem.Allocator, chunk: []const u8) !void {
        self.c.bytes += chunk.len;
        if (self.flags.lines) self.c.lines += common.countByte(chunk, '\n');
        if (!self.needScan()) return;
        if (!self.utf8 or (self.carry_len == 0 and uni.isAscii(chunk))) {
            if (self.flags.maxlen) {
                self.scalarAscii(chunk);
            } else if (self.flags.words) {
                self.c.words += wordsAscii(chunk, &self.in_word);
            }
            self.c.chars += chunk.len;
            return;
        }
        var data = chunk;
        if (self.carry_len > 0) {
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(alloc, self.carry[0..self.carry_len]);
            try self.scratch.appendSlice(alloc, chunk);
            data = self.scratch.items;
            self.carry_len = 0;
        }
        var i: usize = 0;
        while (i < data.len) {
            const b = data[i];
            if (b < 0x80) {
                self.stepAscii(b);
                self.c.chars += 1;
                i += 1;
                continue;
            }
            switch (uni.decode(data[i..])) {
                .ok => |d| {
                    self.c.chars += 1;
                    self.stepCp(d.cp);
                    i += d.len;
                },
                .invalid => i += 1,
                .incomplete => {
                    const rest = data[i..];
                    @memcpy(self.carry[0..rest.len], rest);
                    self.carry_len = rest.len;
                    break;
                },
            }
        }
    }

    fn stepAscii(self: *Counter, b: u8) void {
        switch (b) {
            '\n', '\r', 0x0c => {
                if (self.pos > self.c.maxlen) self.c.maxlen = self.pos;
                self.pos = 0;
                self.in_word = false;
            },
            '\t' => {
                self.pos += 8 - (self.pos % 8);
                self.in_word = false;
            },
            ' ' => {
                self.pos += 1;
                self.in_word = false;
            },
            0x0b => self.in_word = false,
            0x21...0x7e => {
                self.pos += 1;
                if (!self.in_word) {
                    self.c.words += 1;
                    self.in_word = true;
                }
            },
            else => {},
        }
    }

    fn stepCp(self: *Counter, cp: u32) void {
        if (!uni.isPrint(cp)) return;
        self.pos += uni.width(cp);
        if (uni.isSpace(cp) or uni.isNbsp(cp)) {
            self.in_word = false;
        } else if (!self.in_word) {
            self.c.words += 1;
            self.in_word = true;
        }
    }

    fn scalarAscii(self: *Counter, buf: []const u8) void {
        for (buf) |b| self.stepAscii(b);
    }

    fn finish(self: *Counter) Counts {
        if (self.pos > self.c.maxlen) self.c.maxlen = self.pos;
        if (!self.utf8) self.c.chars = self.c.bytes;
        return self.c;
    }
};

fn wordsAscii(buf: []const u8, in_word: *bool) u64 {
    const L = 32;
    const V = @Vector(L, u8);
    const sp_c: V = @splat(' ');
    const lo9: V = @splat(9);
    const hi13: V = @splat(13);
    const lo21: V = @splat(0x21);
    const hi7e: V = @splat(0x7e);
    var words: u64 = 0;
    var prev = in_word.*;
    var i: usize = 0;
    while (buf.len - i >= L) : (i += L) {
        const c: V = buf[i..][0..L].*;
        const is_sp = (c == sp_c) | ((c >= lo9) & (c <= hi13));
        const is_w = (c >= lo21) & (c <= hi7e);
        const sp_m: u32 = @bitCast(is_sp);
        const w_m: u32 = @bitCast(is_w);
        if ((sp_m | w_m) == 0xffffffff) {
            const shifted = (w_m << 1) | @intFromBool(prev);
            words += @popCount(w_m & ~shifted);
            prev = (w_m >> 31) != 0;
        } else {
            for (buf[i..][0..L]) |b| {
                switch (b) {
                    9...13, ' ' => prev = false,
                    0x21...0x7e => {
                        if (!prev) {
                            words += 1;
                            prev = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    while (i < buf.len) : (i += 1) {
        switch (buf[i]) {
            9...13, ' ' => prev = false,
            0x21...0x7e => {
                if (!prev) {
                    words += 1;
                    prev = true;
                }
            },
            else => {},
        }
    }
    in_word.* = prev;
    return words;
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn digits(n: u64) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

const FileInfo = struct { regular: bool, size: u64 };

fn statPath(ctx: *Ctx, path: []const u8) ?FileInfo {
    var pb: [common.path_max]u8 = undefined;
    const full = common.joinCwd(&pb, ctx.cwd, path) catch return null;
    const st = Io.Dir.cwd().statFile(ctx.io, full, .{}) catch return null;
    return .{ .regular = st.kind == .file, .size = st.size };
}

fn computeWidth(ctx: *Ctx, files: []const []const u8, ncols: u32) usize {
    if (files.len == 0) return if (ncols == 1) 1 else 7;
    if (files.len == 1 and ncols == 1) return 1;
    var min_width: usize = 1;
    var total: u64 = 0;
    for (files) |f| {
        if (common.isDashOperand(f)) {
            min_width = 7;
            continue;
        }
        const info = statPath(ctx, f) orelse continue;
        if (info.regular) total += info.size else min_width = 7;
    }
    return @max(digits(total), min_width);
}

fn printCounts(w: *Io.Writer, flags: Flags, c: Counts, width: usize, name: ?[]const u8) !void {
    var first = true;
    const vals = [_]struct { on: bool, v: u64 }{
        .{ .on = flags.lines, .v = c.lines },
        .{ .on = flags.words, .v = c.words },
        .{ .on = flags.chars, .v = c.chars },
        .{ .on = flags.bytes, .v = c.bytes },
        .{ .on = flags.maxlen, .v = c.maxlen },
    };
    for (vals) |e| {
        if (!e.on) continue;
        if (!first) try common.putByte(w, ' ');
        first = false;
        try common.putUintPad(w, e.v, width);
    }
    if (name) |n| {
        try common.putByte(w, ' ');
        try common.put(w, n);
    }
    try common.putByte(w, '\n');
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog = argv[0];
    var flags: Flags = .{};
    var p = common.Parser.init(argv, &specs, io.err);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.alloc);
    while (true) {
        const it = (p.next() catch return 1) orelse break;
        switch (it) {
            .operand => |o| try files.append(ctx.alloc, o),
            .opt => |m| switch (m.id) {
                'l' => flags.lines = true,
                'w' => flags.words = true,
                'm' => flags.chars = true,
                'c' => flags.bytes = true,
                'L' => flags.maxlen = true,
                else => unreachable,
            },
        }
    }
    if (flags.count() == 0) {
        flags.lines = true;
        flags.words = true;
        flags.bytes = true;
    }
    const utf8 = common.isUtf8Locale(ctx.env);
    const ncols = flags.count();
    const width = computeWidth(ctx, files.items, ncols);
    var status: u8 = 0;
    var total: Counts = .{};
    if (files.items.len == 0) {
        var ctr: Counter = .{ .flags = flags, .utf8 = utf8 };
        defer ctr.scratch.deinit(ctx.alloc);
        countStream(ctx, &ctr, io.in) catch |e| switch (e) {
            error.ReadFailed => {
                common.errFmt(io, prog, "standard input: Input/output error", .{});
                status = 1;
            },
            else => |other| return other,
        };
        try printCounts(io.out, flags, ctr.finish(), width, null);
        return status;
    }
    for (files.items) |name| {
        var in: common.Input = .{};
        in.open(ctx, io, name) catch |e| {
            common.fileErrReason(ctx, io, prog, "", name, false, "", common.errnoText(e));
            status = 1;
            continue;
        };
        defer in.close();
        var ctr: Counter = .{ .flags = flags, .utf8 = utf8 };
        defer ctr.scratch.deinit(ctx.alloc);
        var done = false;
        if (!in.stdin and flags.bytes and flags.count() == 1 and in.src.kind == .file and in.src.size > 0) {
            ctr.c.bytes = in.src.size;
            done = true;
        }
        if (!done) {
            countStream(ctx, &ctr, in.r) catch |e| switch (e) {
                error.ReadFailed => {
                    common.fileErrReason(ctx, io, prog, "", name, false, "", in.readErr());
                    status = 1;
                },
                else => |other| return other,
            };
        }
        const c = ctr.finish();
        total.lines += c.lines;
        total.words += c.words;
        total.chars += c.chars;
        total.bytes += c.bytes;
        total.maxlen = @max(total.maxlen, c.maxlen);
        try printCounts(io.out, flags, c, width, name);
    }
    if (files.items.len > 1) try printCounts(io.out, flags, total, width, "total");
    return status;
}

fn countStream(ctx: *Ctx, ctr: *Counter, r: *Io.Reader) common.IoError!void {
    while (try common.nextChunk(r)) |c| try ctr.feed(ctx.alloc, c);
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "wc basic" {
    try t(&.{"wc"}, "a b\nc\n", "      2       3       6\n");
    try t(&.{ "wc", "-l" }, "a\nb\nc", "2\n");
    try t(&.{ "wc", "-w" }, "  a  b\tc\n\nd", "4\n");
    try t(&.{ "wc", "-c" }, "abc", "3\n");
    try t(&.{ "wc", "-L" }, "ab\nabcd\tx\n", "9\n");
    try t(&.{ "wc", "-lw" }, "", "      0       0\n");
}

test "wc words with neutral bytes" {
    try t(&.{ "wc", "-w" }, "a\x01b c\x80d \x01 e", "3\n");
    var big: [100]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = if (i % 5 == 4) ' ' else 'x';
    try t(&.{ "wc", "-w" }, &big, "20\n");
}

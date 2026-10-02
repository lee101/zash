const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const specs = [_]common.OptSpec{
    .{ .id = 'A', .short = 'A', .long = "show-all" },
    .{ .id = 'b', .short = 'b', .long = "number-nonblank" },
    .{ .id = 'e', .short = 'e' },
    .{ .id = 'E', .short = 'E', .long = "show-ends" },
    .{ .id = 'n', .short = 'n', .long = "number" },
    .{ .id = 's', .short = 's', .long = "squeeze-blank" },
    .{ .id = 't', .short = 't' },
    .{ .id = 'T', .short = 'T', .long = "show-tabs" },
    .{ .id = 'u', .short = 'u' },
    .{ .id = 'v', .short = 'v', .long = "show-nonprinting" },
};

pub fn supports(argv: []const []const u8) bool {
    var p = common.Parser.init(argv, &specs, null);
    while (p.next() catch return false) |_| {}
    return true;
}

const Config = struct {
    number: bool = false,
    nonblank: bool = false,
    ends: bool = false,
    squeeze: bool = false,
    tabs: bool = false,
    nonprint: bool = false,

    fn simple(self: Config) bool {
        return !(self.number or self.ends or self.squeeze or self.tabs or self.nonprint);
    }
};

const State = struct {
    newlines: i32 = 0,
    line_no: u64 = 0,
};

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    const prog = argv[0];
    var cfg: Config = .{};
    var p = common.Parser.init(argv, &specs, io.err);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.alloc);
    while (true) {
        const it = (p.next() catch return 1) orelse break;
        switch (it) {
            .operand => |o| try files.append(ctx.alloc, o),
            .opt => |m| switch (m.id) {
                'A' => {
                    cfg.nonprint = true;
                    cfg.ends = true;
                    cfg.tabs = true;
                },
                'b' => {
                    cfg.number = true;
                    cfg.nonblank = true;
                },
                'e' => {
                    cfg.nonprint = true;
                    cfg.ends = true;
                },
                'E' => cfg.ends = true,
                'n' => cfg.number = true,
                's' => cfg.squeeze = true,
                't' => {
                    cfg.nonprint = true;
                    cfg.tabs = true;
                },
                'T' => cfg.tabs = true,
                'u' => {},
                'v' => cfg.nonprint = true,
                else => unreachable,
            },
        }
    }
    if (files.items.len == 0) try files.append(ctx.alloc, "-");
    var status: u8 = 0;
    var st: State = .{};
    const simple = cfg.simple();
    for (files.items) |name| {
        var in: common.Input = .{};
        in.open(ctx, io, name) catch |e| {
            common.fileErrReason(ctx, io, prog, "", name, false, "", common.errnoText(e));
            status = 1;
            continue;
        };
        defer in.close();
        const res = if (simple) copyAll(in.r, io.out) else catAll(in.r, io.out, cfg, &st);
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

fn copyAll(r: *Io.Reader, w: *Io.Writer) common.IoError!void {
    while (try common.nextChunk(r)) |c| try common.put(w, c);
}

const Special = blk: {
    var tbl: [256]u8 = undefined;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        var v: u8 = 0;
        if (c != '\n' and c != '\t' and (c < 32 or c >= 127)) v |= 1;
        if (c == '\t') v |= 2;
        tbl[i] = v;
    }
    break :blk tbl;
};

fn emitSeg(w: *Io.Writer, seg: []const u8, cfg: Config) common.IoError!void {
    if (!cfg.nonprint and !cfg.tabs) return common.put(w, seg);
    const mask: u8 = (if (cfg.nonprint) @as(u8, 1) else 0) | (if (cfg.tabs) @as(u8, 2) else 0);
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < seg.len) : (i += 1) {
        const c = seg[i];
        if (Special[c] & mask == 0) continue;
        if (i > run_start) try common.put(w, seg[run_start..i]);
        run_start = i + 1;
        if (c == '\t') {
            try common.put(w, "^I");
        } else if (c < 32) {
            try common.put(w, &.{ '^', c + 64 });
        } else if (c == 127) {
            try common.put(w, "^?");
        } else if (c >= 160) {
            try common.put(w, "M-");
            if (c < 255) try common.putByte(w, c - 128) else try common.put(w, "^?");
        } else {
            try common.put(w, &.{ 'M', '-', '^', c - 128 + 64 });
        }
    }
    if (seg.len > run_start) try common.put(w, seg[run_start..]);
}

fn putNumber(w: *Io.Writer, st: *State) common.IoError!void {
    st.line_no += 1;
    try common.putUintPad(w, st.line_no, 6);
    try common.putByte(w, '\t');
}

fn catAll(r: *Io.Reader, w: *Io.Writer, cfg: Config, st: *State) common.IoError!void {
    while (try common.nextChunk(r)) |chunk| {
        var i: usize = 0;
        while (i < chunk.len) {
            const j = std.mem.findScalarPos(u8, chunk, i, '\n') orelse chunk.len;
            if (j > i) {
                if (st.newlines >= 0 and cfg.number) try putNumber(w, st);
                st.newlines = -1;
                try emitSeg(w, chunk[i..j], cfg);
            }
            if (j == chunk.len) break;
            st.newlines += 1;
            i = j + 1;
            if (st.newlines > 0) {
                if (st.newlines >= 2) {
                    if (cfg.squeeze) {
                        st.newlines = 2;
                        continue;
                    }
                    st.newlines = 2;
                }
                if (cfg.number and !cfg.nonblank) try putNumber(w, st);
            }
            if (cfg.ends) try common.putByte(w, '$');
            try common.putByte(w, '\n');
        }
    }
}

fn t(argv: []const []const u8, input: []const u8, want: []const u8) !void {
    return common.expectRun(run, argv, input, want, 0);
}

test "cat plain and numbered" {
    try t(&.{"cat"}, "a\nb", "a\nb");
    try t(&.{ "cat", "-n" }, "a\n\nb", "     1\ta\n     2\t\n     3\tb");
    try t(&.{ "cat", "-b" }, "a\n\nb\n", "     1\ta\n\n     2\tb\n");
    try t(&.{ "cat", "-s" }, "a\n\n\n\nb\n", "a\n\nb\n");
    try t(&.{ "cat", "-s" }, "\n\n\na\n", "\na\n");
    try t(&.{ "cat", "-E" }, "a\n\nb", "a$\n$\nb");
    try t(&.{ "cat", "-A" }, "a\tb\x01\x7f\xff\xe9\x80\n", "a^Ib^A^?M-^?M-iM-^@$\n");
    try t(&.{ "cat", "-T" }, "a\tb\n", "a^Ib\n");
    try t(&.{ "cat", "-v" }, "a\tb\x01\n", "a\tb^A\n");
}

test "cat supports" {
    try std.testing.expect(supports(&.{ "cat", "-n", "f" }));
    try std.testing.expect(supports(&.{ "cat", "--number-nonblank", "-s" }));
    try std.testing.expect(!supports(&.{ "cat", "--help" }));
    try std.testing.expect(!supports(&.{ "cat", "-x" }));
}

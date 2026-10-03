const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const EnvView = struct {
    context: ?*const anyopaque = null,
    get_fn: *const fn (?*const anyopaque, []const u8) ?[]const u8 = noEnv,

    pub const empty: EnvView = .{};

    pub fn get(self: *const EnvView, key: []const u8) ?[]const u8 {
        return self.get_fn(self.context, key);
    }

    pub const Pairs = []const [2][]const u8;

    pub fn fromPairs(pairs: *const Pairs) EnvView {
        return .{ .context = pairs, .get_fn = pairsGet };
    }

    fn noEnv(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }

    fn pairsGet(context: ?*const anyopaque, key: []const u8) ?[]const u8 {
        const pairs: *const Pairs = @ptrCast(@alignCast(context.?));
        for (pairs.*) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

pub const Stdio = struct {
    in: *Io.Reader,
    out: *Io.Writer,
    err: *Io.Writer,
};

pub const Ctx = struct {
    alloc: Allocator,
    io: Io,
    cwd: []const u8,
    env: *const EnvView,
    out_null: bool = false,
};

pub const UtilFn = *const fn (ctx: *Ctx, argv: []const []const u8, io: Stdio) u8;
pub const SupportsFn = *const fn (argv: []const []const u8) bool;
pub const SupportsEnvFn = *const fn (env: *const EnvView, argv: []const []const u8) bool;

pub const IoError = error{ ReadFailed, WriteFailed, OutOfMemory };

pub const exit_sigpipe: u8 = 141;

pub fn finish(e: anyerror, prog: []const u8, io: Stdio) u8 {
    switch (e) {
        error.WriteFailed => return exit_sigpipe,
        error.OutOfMemory => {
            errLine(io, prog, "memory exhausted");
            return 1;
        },
        else => {
            errLine(io, prog, "read error");
            return 1;
        },
    }
}

pub fn errLine(io: Stdio, prog: []const u8, msg: []const u8) void {
    io.err.writeAll(prog) catch return;
    io.err.writeAll(": ") catch return;
    io.err.writeAll(msg) catch return;
    io.err.writeByte('\n') catch return;
    io.err.flush() catch {};
}

pub fn errFmt(io: Stdio, prog: []const u8, comptime fmt: []const u8, args: anytype) void {
    io.err.writeAll(prog) catch return;
    io.err.writeAll(": ") catch return;
    io.err.print(fmt, args) catch return;
    io.err.writeByte('\n') catch return;
    io.err.flush() catch {};
}

pub fn errRaw(io: Stdio, comptime fmt: []const u8, args: anytype) void {
    io.err.print(fmt, args) catch return;
    io.err.flush() catch {};
}

pub inline fn put(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    const room = w.buffer.len - w.end;
    if (bytes.len <= room) {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += bytes.len;
        return;
    }
    return w.writeAll(bytes);
}

pub inline fn putByte(w: *Io.Writer, b: u8) Io.Writer.Error!void {
    if (w.end < w.buffer.len) {
        w.buffer[w.end] = b;
        w.end += 1;
        return;
    }
    return w.writeByte(b);
}

pub fn putLine(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
    const room = w.buffer.len - w.end;
    if (bytes.len < room) {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.buffer[w.end + bytes.len] = '\n';
        w.end += bytes.len + 1;
        return;
    }
    try w.writeAll(bytes);
    try w.writeByte('\n');
}

pub fn putUint(w: *Io.Writer, value: u64) Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    try put(w, buf[i..]);
}

pub fn putUintPad(w: *Io.Writer, value: u64, width: usize) Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    var pad = width -| (buf.len - i);
    while (pad > 0) : (pad -= 1) try putByte(w, ' ');
    try put(w, buf[i..]);
}

pub fn countByte(buf: []const u8, byte: u8) usize {
    const L = 32;
    const V = @Vector(L, u8);
    const needle: V = @splat(byte);
    const one: V = @splat(1);
    const zero: V = @splat(0);
    var total: usize = 0;
    var i: usize = 0;
    while (buf.len - i >= L * 8) {
        var acc: V = zero;
        const rounds = @min((buf.len - i) / L, 255);
        for (0..rounds) |_| {
            const chunk: V = buf[i..][0..L].*;
            acc +%= @select(u8, chunk == needle, one, zero);
            i += L;
        }
        const wide: @Vector(L, u16) = acc;
        total += @reduce(.Add, wide);
    }
    while (i < buf.len) : (i += 1) total += @intFromBool(buf[i] == byte);
    return total;
}

pub fn findLastByte(buf: []const u8, byte: u8) ?usize {
    const L = 32;
    const V = @Vector(L, u8);
    const needle: V = @splat(byte);
    var end = buf.len;
    while (end >= L) {
        const chunk: V = buf[end - L ..][0..L].*;
        const mask: u32 = @bitCast(chunk == needle);
        if (mask != 0) return end - L + (31 - @clz(mask));
        end -= L;
    }
    while (end > 0) {
        end -= 1;
        if (buf[end] == byte) return end;
    }
    return null;
}

pub fn findByte(buf: []const u8, byte: u8) ?usize {
    return std.mem.findScalar(u8, buf, byte);
}

pub fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

pub const path_max = 4096;

pub fn joinCwd(buf: *[path_max]u8, cwd: []const u8, path: []const u8) error{NameTooLong}![]const u8 {
    if (isAbsolute(path) or cwd.len == 0 or std.mem.eql(u8, cwd, ".")) return path;
    const need = cwd.len + 1 + path.len;
    if (need > buf.len) return error.NameTooLong;
    @memcpy(buf[0..cwd.len], cwd);
    var n = cwd.len;
    if (cwd[n - 1] != '/') {
        buf[n] = '/';
        n += 1;
    }
    @memcpy(buf[n..][0..path.len], path);
    return buf[0 .. n + path.len];
}

pub fn errnoText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.ProcessFdQuotaExceeded => "Too many open files",
        error.SystemFdQuotaExceeded => "Too many open files in system",
        error.NoDevice => "No such device or address",
        error.SystemResources, error.OutOfMemory => "Cannot allocate memory",
        error.FileTooBig => "File too large",
        error.DeviceBusy, error.FileBusy => "Device or resource busy",
        error.PathAlreadyExists => "File exists",
        error.NoSpaceLeft => "No space left on device",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => "Invalid argument",
        error.NotOpenForReading => "Bad file descriptor",
        error.DirNotEmpty => "Directory not empty",
        error.LinkQuotaExceeded => "Too many links",
        error.CrossDevice => "Invalid cross-device link",
        error.WouldBlock => "Resource temporarily unavailable",
        error.BrokenPipe => "Broken pipe",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.NotSupported => "Operation not supported",
        error.FileLocksUnsupported => "Operation not supported",
        error.ConnectionTimedOut => "Connection timed out",
        else => "Input/output error",
    };
}

pub fn effectiveLocale(env: *const EnvView, category: []const u8) ?[]const u8 {
    if (env.get("LC_ALL")) |v| if (v.len > 0) return v;
    if (env.get(category)) |v| if (v.len > 0) return v;
    if (env.get("LANG")) |v| if (v.len > 0) return v;
    return null;
}

pub const LocaleKind = enum { c, utf8, other };

fn kindOf(v: ?[]const u8) LocaleKind {
    const name = v orelse return .c;
    if (std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX")) return .c;
    var i: usize = 0;
    while (i + 4 <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i..][0..4], "utf8")) return .utf8;
        if (i + 5 <= name.len and std.ascii.eqlIgnoreCase(name[i..][0..5], "utf-8")) return .utf8;
    }
    return .other;
}

pub fn ctypeKind(env: *const EnvView) LocaleKind {
    return kindOf(effectiveLocale(env, "LC_CTYPE"));
}

pub fn isUtf8Locale(env: *const EnvView) bool {
    return ctypeKind(env) == .utf8;
}

pub fn localeIsCLike(env: *const EnvView, comptime category: []const u8) bool {
    const v = effectiveLocale(env, category) orelse return true;
    return std.mem.eql(u8, v, "C") or std.mem.eql(u8, v, "POSIX") or
        std.mem.eql(u8, v, "C.UTF-8") or std.mem.eql(u8, v, "C.utf8") or std.mem.eql(u8, v, "C.UTF8");
}

pub const Quotes = struct { l: []const u8, r: []const u8 };

pub fn quotes(env: *const EnvView) Quotes {
    if (isUtf8Locale(env)) return .{ .l = "\u{2018}", .r = "\u{2019}" };
    return .{ .l = "'", .r = "'" };
}

pub const ArgKind = enum { none, required, optional };

pub const OptSpec = struct {
    id: u16,
    short: u8 = 0,
    long: []const u8 = "",
    arg: ArgKind = .none,
};

pub const Match = struct {
    id: u16,
    arg: ?[]const u8 = null,
    long: bool = false,
};

pub const Item = union(enum) {
    opt: Match,
    operand: []const u8,
};

pub const ParseError = error{Usage};

pub const Parser = struct {
    argv: []const []const u8,
    specs: []const OptSpec,
    prog: []const u8,
    err: ?*Io.Writer = null,
    i: usize = 1,
    cluster: []const u8 = "",
    done: bool = false,
    digits_id: ?u16 = null,
    posix: bool = false,
    seen_operand: bool = false,

    pub fn init(argv: []const []const u8, specs: []const OptSpec, err: ?*Io.Writer) Parser {
        return .{
            .argv = argv,
            .specs = specs,
            .prog = if (argv.len > 0) argv[0] else "",
            .err = err,
        };
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        if (self.err) |w| {
            w.print("{s}: " ++ fmt ++ "\nTry '{s} --help' for more information.\n", .{self.prog} ++ args ++ .{self.prog}) catch {};
            w.flush() catch {};
        }
        return error.Usage;
    }

    pub fn next(self: *Parser) ParseError!?Item {
        if (self.cluster.len > 0) return self.nextShort();
        if (self.i >= self.argv.len) return null;
        const arg = self.argv[self.i];
        if (self.done or arg.len < 2 or arg[0] != '-') {
            self.i += 1;
            if (self.posix) self.done = true;
            return .{ .operand = arg };
        }
        if (arg.len == 2 and arg[1] == '-') {
            self.done = true;
            self.i += 1;
            return self.next();
        }
        if (arg[1] == '-') return self.nextLong(arg);
        self.cluster = arg[1..];
        self.i += 1;
        return self.nextShort();
    }

    fn nextShort(self: *Parser) ParseError!?Item {
        const c = self.cluster[0];
        if (self.digits_id) |did| {
            if (c >= '0' and c <= '9') {
                var n: usize = 0;
                while (n < self.cluster.len and self.cluster[n] >= '0' and self.cluster[n] <= '9') n += 1;
                const digits = self.cluster[0..n];
                self.cluster = self.cluster[n..];
                return .{ .opt = .{ .id = did, .arg = digits } };
            }
        }
        const rest = self.cluster[1..];
        var found: ?OptSpec = null;
        for (self.specs) |s| {
            if (s.short == c) {
                found = s;
                break;
            }
        }
        const spec = found orelse {
            self.cluster = "";
            return self.fail("invalid option -- '{c}'", .{c});
        };
        switch (spec.arg) {
            .none => {
                self.cluster = rest;
                return .{ .opt = .{ .id = spec.id } };
            },
            .optional => {
                self.cluster = "";
                return .{ .opt = .{ .id = spec.id, .arg = if (rest.len > 0) rest else null } };
            },
            .required => {
                self.cluster = "";
                if (rest.len > 0) return .{ .opt = .{ .id = spec.id, .arg = rest } };
                if (self.i < self.argv.len) {
                    const a = self.argv[self.i];
                    self.i += 1;
                    return .{ .opt = .{ .id = spec.id, .arg = a } };
                }
                return self.fail("option requires an argument -- '{c}'", .{c});
            },
        }
    }

    fn nextLong(self: *Parser, arg: []const u8) ParseError!?Item {
        self.i += 1;
        const body = arg[2..];
        const eq = std.mem.findScalar(u8, body, '=');
        const name = if (eq) |e| body[0..e] else body;
        const val: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
        var exact: ?OptSpec = null;
        var cand: ?OptSpec = null;
        var ambiguous = false;
        for (self.specs) |s| {
            if (s.long.len == 0) continue;
            if (std.mem.eql(u8, s.long, name)) {
                exact = s;
                break;
            }
            if (std.mem.startsWith(u8, s.long, name)) {
                if (cand) |c| {
                    if (c.id != s.id or c.arg != s.arg) ambiguous = true;
                } else cand = s;
            }
        }
        const spec = exact orelse blk: {
            if (ambiguous) {
                if (self.err) |w| {
                    w.print("{s}: option '--{s}' is ambiguous; possibilities:", .{ self.prog, name }) catch {};
                    for (self.specs) |s| if (s.long.len > 0 and std.mem.startsWith(u8, s.long, name)) w.print(" '--{s}'", .{s.long}) catch {};
                    w.print("\nTry '{s} --help' for more information.\n", .{self.prog}) catch {};
                    w.flush() catch {};
                }
                return error.Usage;
            }
            break :blk cand orelse return self.fail("unrecognized option '--{s}'", .{name});
        };
        switch (spec.arg) {
            .none => {
                if (val != null) return self.fail("option '--{s}' doesn't allow an argument", .{spec.long});
                return .{ .opt = .{ .id = spec.id, .long = true } };
            },
            .optional => return .{ .opt = .{ .id = spec.id, .arg = val, .long = true } },
            .required => {
                if (val) |v| return .{ .opt = .{ .id = spec.id, .arg = v, .long = true } };
                if (self.i < self.argv.len) {
                    const a = self.argv[self.i];
                    self.i += 1;
                    return .{ .opt = .{ .id = spec.id, .arg = a, .long = true } };
                }
                return self.fail("option '--{s}' requires an argument", .{spec.long});
            },
        }
    }
};

pub const SizeParse = struct { value: u64, overflow: bool = false };

pub fn parseSize(s: []const u8) ?SizeParse {
    var i: usize = 0;
    var v: u64 = 0;
    var overflow = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        const d = s[i] - '0';
        const m = @mulWithOverflow(v, 10);
        const a = @addWithOverflow(m[0], d);
        if (m[1] != 0 or a[1] != 0) overflow = true;
        v = a[0];
    }
    if (i == 0) return null;
    if (overflow) v = std.math.maxInt(u64);
    const suf = s[i..];
    if (suf.len == 0) return .{ .value = v, .overflow = overflow };
    var mult: u64 = 1;
    var base: u64 = 1024;
    var rest = suf[1..];
    switch (suf[0]) {
        'b' => {
            mult = 512;
            if (rest.len != 0) return null;
        },
        'B' => {
            return null;
        },
        'k', 'K' => mult = 1024,
        'm', 'M' => mult = 1024 * 1024,
        'g', 'G' => mult = 1 << 30,
        't', 'T' => mult = 1 << 40,
        'p', 'P' => mult = 1 << 50,
        'e', 'E' => mult = 1 << 60,
        else => return null,
    }
    if (rest.len > 0) {
        if (rest.len == 1 and rest[0] == 'B') {
            base = 1000;
            rest = "";
        } else if (rest.len == 2 and rest[0] == 'i' and rest[1] == 'B') {
            rest = "";
        } else return null;
    }
    if (base == 1000) {
        mult = switch (suf[0]) {
            'k', 'K' => 1000,
            'm', 'M' => 1000 * 1000,
            'g', 'G' => 1000 * 1000 * 1000,
            't', 'T' => 1000_000_000_000,
            'p', 'P' => 1000_000_000_000_000,
            'e', 'E' => 1000_000_000_000_000_000,
            else => return null,
        };
    }
    const m = @mulWithOverflow(v, mult);
    if (m[1] != 0) return .{ .value = std.math.maxInt(u64), .overflow = true };
    return .{ .value = m[0], .overflow = overflow };
}

pub fn parseUint(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const m = @mulWithOverflow(v, 10);
        const a = @addWithOverflow(m[0], c - '0');
        if (m[1] != 0 or a[1] != 0) return std.math.maxInt(u64);
        v = a[0];
    }
    return v;
}

pub const LineReader = struct {
    r: *Io.Reader,
    alloc: Allocator,
    delim: u8 = '\n',
    spill: std.ArrayList(u8) = .empty,
    spill_live: bool = false,

    pub const Line = struct { bytes: []const u8, terminated: bool };

    pub fn init(alloc: Allocator, r: *Io.Reader, delim: u8) LineReader {
        return .{ .r = r, .alloc = alloc, .delim = delim };
    }

    pub fn deinit(self: *LineReader) void {
        self.spill.deinit(self.alloc);
    }

    pub inline fn next(self: *LineReader) IoError!?Line {
        if (!self.spill_live) {
            const buf = self.r.buffered();
            if (std.mem.findScalar(u8, buf, self.delim)) |i| {
                self.r.toss(i + 1);
                return .{ .bytes = buf[0..i], .terminated = true };
            }
        }
        return self.slow();
    }

    fn slow(self: *LineReader) IoError!?Line {
        const r = self.r;
        if (self.spill_live) {
            self.spill.clearRetainingCapacity();
            self.spill_live = false;
            const buf = r.buffered();
            if (std.mem.findScalar(u8, buf, self.delim)) |i| {
                r.toss(i + 1);
                return .{ .bytes = buf[0..i], .terminated = true };
            }
        }
        while (true) {
            const buf = r.buffered();
            if (std.mem.findScalar(u8, buf, self.delim)) |i| {
                if (self.spill.items.len == 0) {
                    r.toss(i + 1);
                    return .{ .bytes = buf[0..i], .terminated = true };
                }
                try self.spill.appendSlice(self.alloc, buf[0..i]);
                r.toss(i + 1);
                self.spill_live = true;
                return .{ .bytes = self.spill.items, .terminated = true };
            }
            if (buf.len > 0) {
                try self.spill.appendSlice(self.alloc, buf);
                r.tossBuffered();
            }
            r.fillMore() catch |e| switch (e) {
                error.EndOfStream => {
                    if (self.spill.items.len == 0) return null;
                    self.spill_live = true;
                    return .{ .bytes = self.spill.items, .terminated = false };
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }
};

pub fn nextChunk(r: *Io.Reader) error{ReadFailed}!?[]const u8 {
    while (true) {
        const n = r.bufferedLen();
        if (n > 0) {
            const b = r.buffered();
            r.tossBuffered();
            return b;
        }
        r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };
    }
}

pub const read_buf_max = 128 * 1024;
pub const read_buf_min = 4096;

pub const FileSrc = struct {
    file: Io.File = undefined,
    fr: Io.File.Reader = undefined,
    buf: []u8 = &.{},
    alloc: Allocator = undefined,
    io: Io = undefined,
    size: u64 = 0,
    kind: Io.File.Kind = .file,
    opened: bool = false,

    pub fn open(self: *FileSrc, ctx: *Ctx, path: []const u8) !void {
        var pb: [path_max]u8 = undefined;
        const full = try joinCwd(&pb, ctx.cwd, path);
        const file = try Io.Dir.cwd().openFile(ctx.io, full, .{});
        errdefer file.close(ctx.io);
        var size: u64 = 0;
        var kind: Io.File.Kind = .file;
        if (file.stat(ctx.io)) |st| {
            size = st.size;
            kind = st.kind;
        } else |_| {}
        const want: usize = if (kind == .file and size < read_buf_max)
            @intCast(@max(size + 1, read_buf_min))
        else
            read_buf_max;
        const buf = try ctx.alloc.alloc(u8, want);
        self.* = .{
            .file = file,
            .buf = buf,
            .alloc = ctx.alloc,
            .io = ctx.io,
            .size = size,
            .kind = kind,
            .opened = true,
        };
        self.fr = if (kind == .file) Io.File.Reader.init(file, ctx.io, buf) else Io.File.Reader.initStreaming(file, ctx.io, buf);
    }

    pub fn reader(self: *FileSrc) *Io.Reader {
        return &self.fr.interface;
    }

    pub fn readErr(self: *FileSrc) []const u8 {
        if (self.fr.err) |e| return errnoText(e);
        return "Input/output error";
    }

    pub fn close(self: *FileSrc) void {
        if (!self.opened) return;
        self.file.close(self.io);
        self.alloc.free(self.buf);
        self.opened = false;
    }
};

pub fn quoteNeeded(name: []const u8) bool {
    if (name.len == 0) return true;
    for (name, 0..) |c, i| {
        switch (c) {
            ' ', '!', '"', '$', '&', '\'', '(', ')', '*', ';', '<', '=', '>', '?', '[', '\\', '^', '`', '|', ':' => return true,
            '#', '~' => if (i == 0) return true,
            0...31, 127 => return true,
            else => {},
        }
    }
    return false;
}

fn utf8SeqLen(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (n > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[0..n]) catch return 0;
    if (cp < 0xa0) return 0;
    return n;
}

pub fn writeQuoted(w: *Io.Writer, name: []const u8, always: bool, utf8: bool) Io.Writer.Error!void {
    var plain_ok = true;
    var has_squote = false;
    var dq_ok = true;
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c >= 128) {
            const n = if (utf8) utf8SeqLen(name[i..]) else 0;
            if (n == 0) {
                plain_ok = false;
                dq_ok = false;
                i += 1;
            } else i += n;
            continue;
        }
        if (c < 32 or c == 127) {
            plain_ok = false;
            dq_ok = false;
        }
        if (c == '\'') has_squote = true;
        if (c == '"' or c == '$' or c == '`' or c == '\\') dq_ok = false;
        i += 1;
    }
    const need = always or quoteNeeded(name) or !plain_ok;
    if (!need) return w.writeAll(name);
    if (has_squote and dq_ok and plain_ok) {
        try w.writeByte('"');
        try w.writeAll(name);
        try w.writeByte('"');
        return;
    }
    try w.writeByte('\'');
    var in_esc = false;
    i = 0;
    while (i < name.len) {
        const c = name[i];
        var n: usize = 1;
        var printable = true;
        if (c >= 128) {
            n = if (utf8) utf8SeqLen(name[i..]) else 0;
            if (n == 0) {
                n = 1;
                printable = false;
            }
        } else if (c < 32 or c == 127) printable = false;
        if (printable) {
            if (in_esc) {
                try w.writeAll("'\'");
                in_esc = false;
            }
            if (c == '\'') {
                try w.writeAll("'\\''");
            } else try w.writeAll(name[i..][0..n]);
        } else {
            if (!in_esc) {
                try w.writeAll("'$'");
                in_esc = true;
            }
            switch (c) {
                7 => try w.writeAll("\\a"),
                8 => try w.writeAll("\\b"),
                9 => try w.writeAll("\\t"),
                10 => try w.writeAll("\\n"),
                11 => try w.writeAll("\\v"),
                12 => try w.writeAll("\\f"),
                13 => try w.writeAll("\\r"),
                else => try w.print("\\{o:0>3}", .{c}),
            }
        }
        i += n;
    }
    if (in_esc) try w.writeByte('\'');
    try w.writeByte('\'');
}

pub fn fileErr(ctx: *Ctx, io: Stdio, prog: []const u8, pre: []const u8, name: []const u8, always: bool, post: []const u8) void {
    fileErrReason(ctx, io, prog, pre, name, always, post, "");
}

pub fn fileErrReason(ctx: *Ctx, io: Stdio, prog: []const u8, pre: []const u8, name: []const u8, always: bool, post: []const u8, reason: []const u8) void {
    const w = io.err;
    w.writeAll(prog) catch return;
    w.writeAll(": ") catch return;
    w.writeAll(pre) catch return;
    writeQuoted(w, name, always, isUtf8Locale(ctx.env)) catch return;
    w.writeAll(post) catch return;
    if (reason.len > 0) {
        w.writeAll(": ") catch return;
        w.writeAll(reason) catch return;
    }
    w.writeByte('\n') catch return;
    w.flush() catch {};
}

pub const Input = struct {
    src: FileSrc = .{},
    stdin: bool = false,
    r: *Io.Reader = undefined,

    pub fn open(self: *Input, ctx: *Ctx, io: Stdio, name: []const u8) !void {
        if (isDashOperand(name)) {
            self.stdin = true;
            self.r = io.in;
            return;
        }
        self.stdin = false;
        try self.src.open(ctx, name);
        self.r = self.src.reader();
    }

    pub fn close(self: *Input) void {
        if (!self.stdin) self.src.close();
    }

    pub fn readErr(self: *Input) []const u8 {
        if (self.stdin) return "Input/output error";
        return self.src.readErr();
    }
};

pub const GlobOpts = struct { pathname: bool = false, period: bool = false, casefold: bool = false };

pub fn globMatch(pat: []const u8, text: []const u8, o: GlobOpts) bool {
    return globAt(pat, 0, text, 0, o);
}

fn globFold(c: u8, o: GlobOpts) u8 {
    return if (o.casefold) std.ascii.toLower(c) else c;
}

fn globClass(name: []const u8, c: u8) ?bool {
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(c);
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(c);
    if (std.mem.eql(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (std.mem.eql(u8, name, "punct")) return c > 32 and c < 127 and !std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "print")) return c >= 32 and c < 127;
    if (std.mem.eql(u8, name, "graph")) return c > 32 and c < 127;
    if (std.mem.eql(u8, name, "cntrl")) return c < 32 or c == 127;
    return null;
}

fn globBracket(pat: []const u8, pi: usize, c: u8, o: GlobOpts) ?struct { matched: bool, next: usize } {
    var i = pi + 1;
    var neg = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        neg = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    const fc = globFold(c, o);
    while (i < pat.len) {
        if (pat[i] == ']' and !first) return .{ .matched = matched != neg, .next = i + 1 };
        first = false;
        if (pat[i] == '[' and i + 1 < pat.len and pat[i + 1] == ':') {
            if (std.mem.findPos(u8, pat, i + 2, ":]")) |e| {
                const r = globClass(pat[i + 2 .. e], c) orelse return null;
                if (r) matched = true;
                i = e + 2;
                continue;
            }
        }
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        i += 1;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            var hi = pat[i + 1];
            i += 2;
            if (hi == '\\' and i < pat.len) {
                hi = pat[i];
                i += 1;
            }
            if (fc >= globFold(lo, o) and fc <= globFold(hi, o)) matched = true;
        } else if (globFold(lo, o) == fc) matched = true;
    }
    return null;
}

fn globAt(pat: []const u8, pi_in: usize, text: []const u8, ti_in: usize, o: GlobOpts) bool {
    var pi = pi_in;
    var ti = ti_in;
    while (pi < pat.len) {
        const p = pat[pi];
        switch (p) {
            '*' => {
                while (pi < pat.len and pat[pi] == '*') pi += 1;
                if (o.period and ti < text.len and text[ti] == '.' and (ti == 0 or (o.pathname and text[ti - 1] == '/'))) return false;
                if (pi == pat.len) {
                    if (o.pathname) return std.mem.findScalar(u8, text[ti..], '/') == null;
                    return true;
                }
                var k = ti;
                while (k <= text.len) : (k += 1) {
                    if (globAt(pat, pi, text, k, o)) return true;
                    if (k < text.len and o.pathname and text[k] == '/') break;
                }
                return false;
            },
            '?' => {
                if (ti >= text.len) return false;
                if (o.pathname and text[ti] == '/') return false;
                if (o.period and text[ti] == '.' and (ti == 0 or (o.pathname and text[ti - 1] == '/'))) return false;
                pi += 1;
                ti += 1;
            },
            '[' => {
                if (ti >= text.len) return false;
                if (o.pathname and text[ti] == '/') return false;
                if (o.period and text[ti] == '.' and (ti == 0 or (o.pathname and text[ti - 1] == '/'))) return false;
                if (globBracket(pat, pi, text[ti], o)) |r| {
                    if (!r.matched) return false;
                    pi = r.next;
                    ti += 1;
                } else {
                    if (text[ti] != '[') return false;
                    pi += 1;
                    ti += 1;
                }
            },
            else => {
                var lit = p;
                if (p == '\\' and pi + 1 < pat.len) {
                    pi += 1;
                    lit = pat[pi];
                }
                if (ti >= text.len) return false;
                if (o.period and lit == '.' and false) return false;
                if (globFold(text[ti], o) != globFold(lit, o)) return false;
                pi += 1;
                ti += 1;
            },
        }
    }
    return ti == text.len;
}

pub fn globMatchSuffix(pat: []const u8, name: []const u8) bool {
    if (globMatch(pat, name, .{})) return true;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '/' and i + 1 < name.len and name[i + 1] != '/') {
            if (globMatch(pat, name[i + 1 ..], .{})) return true;
        }
    }
    return false;
}

pub const DirEntry = struct { name: []u8, kind: Io.File.Kind };

pub const DirList = struct {
    items: std.ArrayList(DirEntry) = .empty,

    pub fn deinit(self: *DirList, alloc: Allocator) void {
        for (self.items.items) |e| alloc.free(e.name);
        self.items.deinit(alloc);
    }
};

pub fn readDirList(ctx: *Ctx, path: []const u8) !DirList {
    var pb: [path_max]u8 = undefined;
    const full = try joinCwd(&pb, ctx.cwd, if (path.len == 0) "." else path);
    var dir = try Io.Dir.cwd().openDir(ctx.io, full, .{ .iterate = true });
    defer dir.close(ctx.io);
    var list: DirList = .{};
    errdefer list.deinit(ctx.alloc);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const name = try ctx.alloc.dupe(u8, e.name);
        errdefer ctx.alloc.free(name);
        try list.items.append(ctx.alloc, .{ .name = name, .kind = e.kind });
    }
    return list;
}

pub fn statKind(ctx: *Ctx, path: []const u8, follow: bool) ?Io.File.Kind {
    var pb: [path_max]u8 = undefined;
    const full = joinCwd(&pb, ctx.cwd, path) catch return null;
    const st = Io.Dir.cwd().statFile(ctx.io, full, .{ .follow_symlinks = follow }) catch return null;
    return st.kind;
}

const byte_rank = blk: {
    var t = [_]u8{128} ** 256;
    const common_bytes = " etaoinshrdlucmfwypvbgkjqxz\n.,-_/:;()=0123456789";
    for (common_bytes, 0..) |c, i| t[c] = @intCast(250 - i);
    for ('A'..'Z' + 1) |c| t[c] = 200;
    t[0] = 255;
    t[0xff] = 5;
    break :blk t;
};

pub fn findBytes(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return if (from <= hay.len) from else null;
    if (hay.len < needle.len or from > hay.len - needle.len) return null;
    if (needle.len == 1) return std.mem.findScalarPos(u8, hay, from, needle[0]);
    var r1: usize = 0;
    for (needle, 0..) |c, i| {
        if (byte_rank[c] < byte_rank[needle[r1]]) r1 = i;
    }
    var r2: usize = if (r1 == 0) needle.len - 1 else 0;
    for (needle, 0..) |c, i| {
        if (i != r1 and byte_rank[c] < byte_rank[needle[r2]]) r2 = i;
    }
    const L = 32;
    const V = @Vector(L, u8);
    const b1: V = @splat(needle[r1]);
    const b2: V = @splat(needle[r2]);
    const last_start = hay.len - needle.len;
    const maxr = @max(r1, r2);
    var i = from;
    while (i + L + maxr <= hay.len) {
        const v1: V = hay[i + r1 ..][0..L].*;
        const v2: V = hay[i + r2 ..][0..L].*;
        var mask: u32 = @bitCast((v1 == b1) & (v2 == b2));
        while (mask != 0) {
            const k = @ctz(mask);
            mask &= mask - 1;
            const pos = i + k;
            if (pos <= last_start and std.mem.eql(u8, hay[pos..][0..needle.len], needle)) return pos;
        }
        i += L;
    }
    while (i <= last_start) : (i += 1) {
        if (hay[i] == needle[0] and std.mem.eql(u8, hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

pub fn findAnyOf(hay: []const u8, from: usize, bytes: []const u8) usize {
    const L = 32;
    const V = @Vector(L, u8);
    var i = from;
    switch (bytes.len) {
        1 => return std.mem.findScalarPos(u8, hay, i, bytes[0]) orelse hay.len,
        2 => {
            const a: V = @splat(bytes[0]);
            const b: V = @splat(bytes[1]);
            while (i + L <= hay.len) : (i += L) {
                const v: V = hay[i..][0..L].*;
                const m: u32 = @bitCast((v == a) | (v == b));
                if (m != 0) return i + @ctz(m);
            }
        },
        3 => {
            const a: V = @splat(bytes[0]);
            const b: V = @splat(bytes[1]);
            const c: V = @splat(bytes[2]);
            while (i + L <= hay.len) : (i += L) {
                const v: V = hay[i..][0..L].*;
                const m: u32 = @bitCast((v == a) | (v == b) | (v == c));
                if (m != 0) return i + @ctz(m);
            }
        },
        else => {},
    }
    while (i < hay.len) : (i += 1) {
        for (bytes) |c| if (hay[i] == c) return i;
    }
    return hay.len;
}

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn findBytesIcase(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return if (from <= hay.len) from else null;
    if (hay.len < needle.len or from > hay.len - needle.len) return null;
    var r1: usize = 0;
    for (needle, 0..) |c, i| {
        if (byte_rank[c] < byte_rank[needle[r1]]) r1 = i;
    }
    var r2: usize = if (r1 == 0) needle.len - 1 else 0;
    if (needle.len == 1) r2 = r1;
    for (needle, 0..) |c, i| {
        if (i != r1 and byte_rank[c] < byte_rank[needle[r2]]) r2 = i;
    }
    const L = 32;
    const V = @Vector(L, u8);
    const f1 = std.ascii.isAlphabetic(needle[r1]);
    const f2 = std.ascii.isAlphabetic(needle[r2]);
    const b1: V = @splat(needle[r1]);
    const b2: V = @splat(needle[r2]);
    const bit: V = @splat(0x20);
    const last_start = hay.len - needle.len;
    const maxr = @max(r1, r2);
    var i = from;
    while (i + L + maxr <= hay.len) {
        var v1: V = hay[i + r1 ..][0..L].*;
        var v2: V = hay[i + r2 ..][0..L].*;
        if (f1) v1 |= bit;
        if (f2) v2 |= bit;
        var mask: u32 = @bitCast((v1 == b1) & (v2 == b2));
        while (mask != 0) {
            const k = @ctz(mask);
            mask &= mask - 1;
            const pos = i + k;
            if (pos <= last_start and eqlIcase(hay[pos..][0..needle.len], needle)) return pos;
        }
        i += L;
    }
    while (i <= last_start) : (i += 1) {
        if (eqlIcase(hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn eqlIcase(a: []const u8, lower_needle: []const u8) bool {
    for (a, lower_needle) |x, y| if (lowerAscii(x) != y) return false;
    return true;
}

pub fn isDashOperand(s: []const u8) bool {
    return s.len == 1 and s[0] == '-';
}

pub const TestResult = struct {
    out: []u8,
    err: []u8,
    status: u8,
    alloc: Allocator,

    pub fn deinit(self: *TestResult) void {
        self.alloc.free(self.out);
        self.alloc.free(self.err);
    }
};

pub fn testRunEnv(alloc: Allocator, run_fn: UtilFn, argv: []const []const u8, stdin: []const u8, env: *const EnvView) !TestResult {
    var ctx: Ctx = .{ .alloc = alloc, .io = std.testing.io, .cwd = ".", .env = env };
    var in_r: Io.Reader = .fixed(stdin);
    var out_w: Io.Writer.Allocating = .init(alloc);
    defer out_w.deinit();
    var err_w: Io.Writer.Allocating = .init(alloc);
    defer err_w.deinit();
    const status = run_fn(&ctx, argv, .{ .in = &in_r, .out = &out_w.writer, .err = &err_w.writer });
    const out = try alloc.dupe(u8, out_w.writer.buffered());
    errdefer alloc.free(out);
    const err = try alloc.dupe(u8, err_w.writer.buffered());
    return .{ .out = out, .err = err, .status = status, .alloc = alloc };
}

pub fn testRun(alloc: Allocator, run_fn: UtilFn, argv: []const []const u8, stdin: []const u8) !TestResult {
    return testRunEnv(alloc, run_fn, argv, stdin, &EnvView.empty);
}

pub fn expectRun(run_fn: UtilFn, argv: []const []const u8, stdin: []const u8, want_out: []const u8, want_status: u8) !void {
    var r = try testRun(std.testing.allocator, run_fn, argv, stdin);
    defer r.deinit();
    try std.testing.expectEqualStrings(want_out, r.out);
    try std.testing.expectEqual(want_status, r.status);
}

test "parser clusters and long options" {
    const specs = [_]OptSpec{
        .{ .id = 'n', .short = 'n', .long = "lines", .arg = .required },
        .{ .id = 'q', .short = 'q', .long = "quiet" },
        .{ .id = 'v', .short = 'v', .long = "verbose" },
    };
    const argv = [_][]const u8{ "head", "-qn5", "file", "--lines=3", "-v", "--", "-q", "--quiet" };
    var p = Parser.init(&argv, &specs, null);
    var seq: [16][]const u8 = undefined;
    var n: usize = 0;
    while (try p.next()) |it| {
        switch (it) {
            .opt => |m| {
                seq[n] = if (m.arg) |a| a else switch (m.id) {
                    'q' => "q",
                    'v' => "v",
                    else => "?",
                };
                n += 1;
            },
            .operand => |o| {
                seq[n] = o;
                n += 1;
            },
        }
    }
    const want = [_][]const u8{ "q", "5", "file", "3", "v", "-q", "--quiet" };
    try std.testing.expectEqual(want.len, n);
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, seq[i]);
}

test "parser abbreviations and errors" {
    const specs = [_]OptSpec{
        .{ .id = 1, .long = "bytes", .arg = .required },
        .{ .id = 2, .long = "quiet" },
        .{ .id = 3, .long = "silent" },
    };
    var p = Parser.init(&.{ "x", "--by=4", "--qui", "--s" }, &specs, null);
    const a = (try p.next()).?.opt;
    try std.testing.expectEqual(@as(u16, 1), a.id);
    try std.testing.expectEqualStrings("4", a.arg.?);
    try std.testing.expectEqual(@as(u16, 2), (try p.next()).?.opt.id);
    try std.testing.expectEqual(@as(u16, 3), (try p.next()).?.opt.id);
    var p2 = Parser.init(&.{ "x", "--nope" }, &specs, null);
    try std.testing.expectError(error.Usage, p2.next());
}

test "parseSize suffixes" {
    try std.testing.expectEqual(@as(u64, 5), parseSize("5").?.value);
    try std.testing.expectEqual(@as(u64, 1024), parseSize("1K").?.value);
    try std.testing.expectEqual(@as(u64, 1000), parseSize("1kB").?.value);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), parseSize("2MiB").?.value);
    try std.testing.expectEqual(@as(u64, 512), parseSize("1b").?.value);
    try std.testing.expect(parseSize("x") == null);
    try std.testing.expect(parseSize("1Q") == null);
    try std.testing.expect(parseSize("99999999999999999999").?.overflow);
}

test "countByte matches scalar" {
    var buf: [5000]u8 = undefined;
    var x: u32 = 12345;
    for (&buf) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @intCast((x >> 24) % 7);
    }
    for ([_]usize{ 0, 1, 31, 32, 255, 256, 257, 2047, 2048, 5000 }) |n| {
        var want: usize = 0;
        for (buf[0..n]) |b| want += @intFromBool(b == 3);
        try std.testing.expectEqual(want, countByte(buf[0..n], 3));
    }
}

test "findLastByte" {
    var buf: [200]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expect(findLastByte(&buf, '\n') == null);
    buf[0] = '\n';
    try std.testing.expectEqual(@as(?usize, 0), findLastByte(&buf, '\n'));
    buf[150] = '\n';
    try std.testing.expectEqual(@as(?usize, 150), findLastByte(&buf, '\n'));
    buf[199] = '\n';
    try std.testing.expectEqual(@as(?usize, 199), findLastByte(&buf, '\n'));
    try std.testing.expectEqual(@as(?usize, 150), findLastByte(buf[0..199], '\n'));
}

test "line reader spans buffer boundaries" {
    const alloc = std.testing.allocator;
    const Tiny = struct {
        data: []const u8,
        pos: usize = 0,
        interface: Io.Reader,

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", r));
            if (self.pos >= self.data.len) return error.EndOfStream;
            const n = @min(3, self.data.len - self.pos, @intFromEnum(limit));
            try w.writeAll(self.data[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
    };
    var buf: [8]u8 = undefined;
    var t: Tiny = .{
        .data = "hello world, this is a long line\nshort\n\nlast",
        .interface = .{ .vtable = &.{ .stream = Tiny.stream }, .buffer = &buf, .seek = 0, .end = 0 },
    };
    var lr = LineReader.init(alloc, &t.interface, '\n');
    defer lr.deinit();
    const want = [_][]const u8{ "hello world, this is a long line", "short", "", "last" };
    for (want, 0..) |w, i| {
        const l = (try lr.next()).?;
        try std.testing.expectEqualStrings(w, l.bytes);
        try std.testing.expectEqual(i != 3, l.terminated);
    }
    try std.testing.expect((try lr.next()) == null);
}

test "findBytes" {
    const hay = "the quick brown fox jumps over the lazy dog, again and again until the end of the haystack xyz";
    const needles = [_][]const u8{ "the", "xyz", "again", "z", "haystack xyz", "dog,", "nope", "ck", "x" };
    for (needles) |n| {
        for (0..hay.len) |from| {
            const want = std.mem.find(u8, hay[from..], n);
            const got = findBytes(hay, n, from);
            try std.testing.expectEqual(if (want) |w| @as(?usize, w + from) else null, got);
        }
    }
}

test "joinCwd" {
    var b: [path_max]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", try joinCwd(&b, ".", "a/b"));
    try std.testing.expectEqualStrings("/x/a/b", try joinCwd(&b, "/x", "a/b"));
    try std.testing.expectEqualStrings("/a", try joinCwd(&b, "/x", "/a"));
}

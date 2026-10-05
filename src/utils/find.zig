const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const fsx = @import("fsx.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const Node = union(enum) {
    name: struct { pat: []const u8, icase: bool },
    path: struct { pat: []const u8, icase: bool },
    type_: u16,
    empty,
    size: struct { n: u64, cmp: std.math.Order, unit: u64 },
    newer: struct { s: i64, ns: u32 },
    prune,
    print,
    print0,
    always: bool,
    not: *Node,
    and_: [2]*Node,
    or_: [2]*Node,
};

const Err = error{ WriteFailed, OutOfMemory };
const ParseError = error{ Unsupported, OutOfMemory, NewerMissing };

const Parse = struct {
    args: []const []const u8,
    i: usize,
    a: std.mem.Allocator,
    ctx: ?*Ctx,
    saw_expr: bool = false,
    has_action: bool = false,
    has_prune: bool = false,
    depth_first: bool = false,
    maxdepth: usize = std.math.maxInt(usize),
    mindepth: usize = 0,
    missing: []const u8 = "",

    fn node(self: *Parse, n: Node) !*Node {
        const p = try self.a.create(Node);
        p.* = n;
        return p;
    }

    fn peek(self: *Parse) ?[]const u8 {
        return if (self.i < self.args.len) self.args[self.i] else null;
    }

    fn parseOr(self: *Parse) ParseError!*Node {
        var left = try self.parseAnd();
        while (self.peek()) |t| {
            if (!(std.mem.eql(u8, t, "-o") or std.mem.eql(u8, t, "-or"))) break;
            self.i += 1;
            self.saw_expr = true;
            const right = try self.parseAnd();
            left = try self.node(.{ .or_ = .{ left, right } });
        }
        return left;
    }

    fn startsPrimary(t: []const u8) bool {
        if (std.mem.eql(u8, t, "-o") or std.mem.eql(u8, t, "-or") or std.mem.eql(u8, t, ")")) return false;
        return true;
    }

    fn parseAnd(self: *Parse) ParseError!*Node {
        var left = try self.parseNot();
        while (self.peek()) |t| {
            if (std.mem.eql(u8, t, "-a") or std.mem.eql(u8, t, "-and")) {
                self.i += 1;
                self.saw_expr = true;
            } else if (!startsPrimary(t)) break;
            const right = try self.parseNot();
            left = try self.node(.{ .and_ = .{ left, right } });
        }
        return left;
    }

    fn parseNot(self: *Parse) ParseError!*Node {
        const t = self.peek() orelse return error.Unsupported;
        if (std.mem.eql(u8, t, "!") or std.mem.eql(u8, t, "-not")) {
            self.i += 1;
            self.saw_expr = true;
            const inner = try self.parseNot();
            return self.node(.{ .not = inner });
        }
        return self.parsePrimary();
    }

    fn arg(self: *Parse) ParseError![]const u8 {
        if (self.i >= self.args.len) return error.Unsupported;
        const v = self.args[self.i];
        self.i += 1;
        return v;
    }

    fn parseUint(s: []const u8) ParseError!usize {
        const v = common.parseUint(s) orelse return error.Unsupported;
        if (v > std.math.maxInt(u32)) return error.Unsupported;
        return @intCast(v);
    }

    fn parsePrimary(self: *Parse) ParseError!*Node {
        const t = self.args[self.i];
        self.i += 1;
        if (std.mem.eql(u8, t, "(")) {
            self.saw_expr = true;
            const inner = try self.parseOr();
            const close = self.peek() orelse return error.Unsupported;
            if (!std.mem.eql(u8, close, ")")) return error.Unsupported;
            self.i += 1;
            return inner;
        }
        if (std.mem.eql(u8, t, "-maxdepth") or std.mem.eql(u8, t, "-mindepth")) {
            if (self.saw_expr) return error.Unsupported;
            const v = try parseUint(try self.arg());
            if (t[1] == 'm' and t[2] == 'a') self.maxdepth = v else self.mindepth = v;
            return self.node(.{ .always = true });
        }
        if (std.mem.eql(u8, t, "-depth")) {
            if (self.saw_expr) return error.Unsupported;
            self.depth_first = true;
            return self.node(.{ .always = true });
        }
        self.saw_expr = true;
        if (std.mem.eql(u8, t, "-name") or std.mem.eql(u8, t, "-iname")) {
            const p = try self.arg();
            if (std.mem.indexOfScalar(u8, p, '/') != null) return error.Unsupported;
            return self.node(.{ .name = .{ .pat = p, .icase = t[1] == 'i' } });
        }
        if (std.mem.eql(u8, t, "-path") or std.mem.eql(u8, t, "-ipath") or std.mem.eql(u8, t, "-wholename") or std.mem.eql(u8, t, "-iwholename")) {
            const p = try self.arg();
            return self.node(.{ .path = .{ .pat = p, .icase = t[1] == 'i' } });
        }
        if (std.mem.eql(u8, t, "-type")) {
            const v = try self.arg();
            if (v.len != 1) return error.Unsupported;
            const bits: u16 = switch (v[0]) {
                'f' => fsx.S_IFREG,
                'd' => fsx.S_IFDIR,
                'l' => fsx.S_IFLNK,
                'p' => fsx.S_IFIFO,
                's' => fsx.S_IFSOCK,
                'b' => fsx.S_IFBLK,
                'c' => fsx.S_IFCHR,
                else => return error.Unsupported,
            };
            return self.node(.{ .type_ = bits });
        }
        if (std.mem.eql(u8, t, "-empty")) return self.node(.empty);
        if (std.mem.eql(u8, t, "-true")) return self.node(.{ .always = true });
        if (std.mem.eql(u8, t, "-false")) return self.node(.{ .always = false });
        if (std.mem.eql(u8, t, "-prune")) {
            self.has_prune = true;
            return self.node(.prune);
        }
        if (std.mem.eql(u8, t, "-print")) {
            self.has_action = true;
            return self.node(.print);
        }
        if (std.mem.eql(u8, t, "-print0")) {
            self.has_action = true;
            return self.node(.print0);
        }
        if (std.mem.eql(u8, t, "-size")) {
            var v = try self.arg();
            var cmp: std.math.Order = .eq;
            if (v.len > 0 and (v[0] == '+' or v[0] == '-')) {
                cmp = if (v[0] == '+') .gt else .lt;
                v = v[1..];
            }
            var unit: u64 = 512;
            if (v.len > 0) switch (v[v.len - 1]) {
                'b' => v = v[0 .. v.len - 1],
                'c' => {
                    unit = 1;
                    v = v[0 .. v.len - 1];
                },
                'w' => {
                    unit = 2;
                    v = v[0 .. v.len - 1];
                },
                'k' => {
                    unit = 1024;
                    v = v[0 .. v.len - 1];
                },
                'M' => {
                    unit = 1 << 20;
                    v = v[0 .. v.len - 1];
                },
                'G' => {
                    unit = 1 << 30;
                    v = v[0 .. v.len - 1];
                },
                else => {},
            };
            if (v.len == 0) return error.Unsupported;
            const n = common.parseUint(v) orelse return error.Unsupported;
            return self.node(.{ .size = .{ .n = n, .cmp = cmp, .unit = unit } });
        }
        if (std.mem.eql(u8, t, "-newer")) {
            const ref = try self.arg();
            var s: i64 = 0;
            var ns: u32 = 0;
            if (self.ctx) |c| {
                const st = fsx.stat(c, ref, false) catch {
                    self.missing = ref;
                    return error.NewerMissing;
                };
                s = st.mtime_s;
                ns = st.mtime_ns;
            }
            return self.node(.{ .newer = .{ .s = s, .ns = ns } });
        }
        return error.Unsupported;
    }
};

fn looksLikeExpr(a: []const u8) bool {
    if (a.len > 1 and a[0] == '-') return true;
    return std.mem.eql(u8, a, "(") or std.mem.eql(u8, a, ")") or std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, ",");
}

const Parsed = struct {
    paths: []const []const u8,
    root: *Node,
    depth_first: bool,
    maxdepth: usize,
    mindepth: usize,
};

fn parseArgs(a: std.mem.Allocator, ctx: ?*Ctx, argv: []const []const u8, missing: *[]const u8) ParseError!Parsed {
    var i: usize = 1;
    while (i < argv.len and std.mem.eql(u8, argv[i], "-P")) i += 1;
    const ps = i;
    while (i < argv.len and !looksLikeExpr(argv[i])) i += 1;
    var p: Parse = .{ .args = argv, .i = i, .a = a, .ctx = ctx };
    var root: *Node = undefined;
    if (i >= argv.len) {
        root = try p.node(.print);
    } else {
        root = p.parseOr() catch |e| {
            missing.* = p.missing;
            return e;
        };
        if (p.i != argv.len) return error.Unsupported;
        if (!p.has_action) {
            const pr = try p.node(.print);
            root = try p.node(.{ .and_ = .{ root, pr } });
        }
    }
    if (p.has_prune and p.depth_first) return error.Unsupported;
    missing.* = p.missing;
    return .{ .paths = argv[ps..i], .root = root, .depth_first = p.depth_first, .maxdepth = p.maxdepth, .mindepth = p.mindepth };
}

fn safeName(s: []const u8) bool {
    for (s) |c| if (c < 32 or c >= 127 or c == '\\' or c == '\'') return false;
    return true;
}

pub fn supports(argv: []const []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var missing: []const u8 = "";
    const p = parseArgs(arena.allocator(), null, argv, &missing) catch return false;
    for (p.paths) |s| if (!safeName(s)) return false;
    return true;
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    if (!supports(argv)) return false;
    if (common.ctypeKind(env) == .c) return true;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 1) {
        const t = argv[i];
        const pat_opt = std.mem.eql(u8, t, "-name") or std.mem.eql(u8, t, "-iname") or std.mem.eql(u8, t, "-path") or std.mem.eql(u8, t, "-ipath") or std.mem.eql(u8, t, "-wholename") or std.mem.eql(u8, t, "-iwholename");
        if (!pat_opt) continue;
        const pat = argv[i + 1];
        if (std.mem.indexOfAny(u8, pat, "?[") != null) return false;
        for (pat) |c| if (c >= 128) return false;
    }
    return true;
}

const Cur = struct {
    path: []const u8,
    base: []const u8,
    depth: usize,
    ty: u16,
    st: ?fsx.St = null,
    pruned: bool = false,
};

const Find = struct {
    ctx: *Ctx,
    io: Stdio,
    prog: []const u8,
    p: Parsed,
    status: u8 = 0,
    utf8: bool,

    fn errPath(self: *Find, path: []const u8, reason: []const u8) void {
        self.io.out.flush() catch {};
        const w = self.io.err;
        w.writeAll(self.prog) catch return;
        w.writeAll(": ") catch return;
        const q = common.quotes(self.ctx.env);
        w.writeAll(q.l) catch return;
        writeEscaped(w, path, self.utf8) catch return;
        w.writeAll(q.r) catch return;
        w.writeAll(": ") catch return;
        w.writeAll(reason) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch {};
        self.status = 1;
    }

    fn ensureStat(self: *Find, c: *Cur) ?fsx.St {
        if (c.st) |s| return s;
        c.st = fsx.stat(self.ctx, c.path, false) catch |e| {
            self.errPath(c.path, fsx.errText(e));
            return null;
        };
        return c.st;
    }

    fn dirEmpty(self: *Find, path: []const u8) bool {
        var dl = common.readDirList(self.ctx, path) catch |e| {
            self.errPath(path, common.errnoText(e));
            return false;
        };
        defer dl.deinit(self.ctx.alloc);
        return dl.items.items.len == 0;
    }

    fn eval(self: *Find, n: *const Node, c: *Cur) Err!bool {
        switch (n.*) {
            .name => |m| return common.globMatch(m.pat, c.base, .{ .casefold = m.icase }),
            .path => |m| return common.globMatch(m.pat, c.path, .{ .casefold = m.icase }),
            .type_ => |t| return c.ty == t,
            .empty => {
                if (c.ty == fsx.S_IFREG) {
                    const s = self.ensureStat(c) orelse return false;
                    return s.size == 0;
                }
                if (c.ty == fsx.S_IFDIR) return self.dirEmpty(c.path);
                return false;
            },
            .size => |m| {
                const s = self.ensureStat(c) orelse return false;
                const units = (s.size + m.unit - 1) / m.unit;
                return std.math.order(units, m.n) == m.cmp;
            },
            .newer => |m| {
                const s = self.ensureStat(c) orelse return false;
                return s.newerThan(m.s, m.ns);
            },
            .prune => {
                c.pruned = true;
                return true;
            },
            .print, .print0 => {
                const w = self.io.out;
                try common.put(w, c.path);
                try common.putByte(w, if (n.* == .print) '\n' else 0);
                return true;
            },
            .always => |b| return b,
            .not => |x| return !(try self.eval(x, c)),
            .and_ => |ab| return (try self.eval(ab[0], c)) and (try self.eval(ab[1], c)),
            .or_ => |ab| return (try self.eval(ab[0], c)) or (try self.eval(ab[1], c)),
        }
    }

    fn visit(self: *Find, c: *Cur) Err!void {
        if (!self.p.depth_first) {
            if (c.depth >= self.p.mindepth) _ = try self.eval(self.p.root, c);
        }
        if (c.ty == fsx.S_IFDIR and c.depth < self.p.maxdepth and !c.pruned) try self.descend(c);
        if (self.p.depth_first) {
            if (c.depth >= self.p.mindepth) _ = try self.eval(self.p.root, c);
        }
    }

    fn descend(self: *Find, c: *Cur) Err!void {
        var dl = common.readDirList(self.ctx, c.path) catch |e| {
            self.errPath(c.path, common.errnoText(e));
            return;
        };
        defer dl.deinit(self.ctx.alloc);
        var arena = std.heap.ArenaAllocator.init(self.ctx.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        for (dl.items.items) |de| {
            const full = try fsx.joinChild(a, c.path, de.name);
            var child: Cur = .{ .path = full, .base = de.name, .depth = c.depth + 1, .ty = kindBits(de.kind) };
            if (child.ty == 0) {
                const st = fsx.stat(self.ctx, full, false) catch |e| {
                    self.errPath(full, fsx.errText(e));
                    continue;
                };
                child.st = st;
                child.ty = st.fmt();
            }
            try self.visit(&child);
        }
    }

    fn start(self: *Find, path: []const u8) Err!void {
        const st = fsx.stat(self.ctx, path, false) catch |e| {
            self.errPath(path, fsx.errText(e));
            return;
        };
        var end = path.len;
        while (end > 1 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        var base = trimmed;
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |k| {
            if (trimmed.len > 1) base = trimmed[k + 1 ..];
        }
        var c: Cur = .{ .path = path, .base = base, .depth = 0, .ty = st.fmt(), .st = st };
        try self.visit(&c);
    }
};

fn kindBits(k: Io.File.Kind) u16 {
    return switch (k) {
        .directory => fsx.S_IFDIR,
        .file => fsx.S_IFREG,
        .sym_link => fsx.S_IFLNK,
        .named_pipe => fsx.S_IFIFO,
        .unix_domain_socket => fsx.S_IFSOCK,
        .block_device => fsx.S_IFBLK,
        .character_device => fsx.S_IFCHR,
        else => 0,
    };
}

fn writeEscaped(w: *Io.Writer, s: []const u8, utf8: bool) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 128 and utf8) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
                try w.writeAll(s[i..][0..n]);
                i += n;
                continue;
            }
        }
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            7 => try w.writeAll("\\a"),
            8 => try w.writeAll("\\b"),
            9 => try w.writeAll("\\t"),
            10 => try w.writeAll("\\n"),
            11 => try w.writeAll("\\v"),
            12 => try w.writeAll("\\f"),
            13 => try w.writeAll("\\r"),
            else => if (c < 32 or c >= 127) try w.print("\\{o:0>3}", .{c}) else try w.writeByte(c),
        }
        i += 1;
    }
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) !u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    var missing: []const u8 = "";
    var f: Find = .{ .ctx = ctx, .io = io, .prog = argv[0], .p = undefined, .utf8 = common.isUtf8Locale(ctx.env) };
    f.p = parseArgs(arena.allocator(), ctx, argv, &missing) catch |e| switch (e) {
        error.NewerMissing => {
            f.errPath(missing, "No such file or directory");
            return 1;
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            common.errLine(io, argv[0], "unsupported expression");
            return 1;
        },
    };
    if (f.p.paths.len == 0) {
        try f.start(".");
    } else for (f.p.paths) |p| try f.start(p);
    try io.out.flush();
    return f.status;
}

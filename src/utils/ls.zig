const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const common = @import("common.zig");
const fsx = @import("fsx.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const NameRec = extern struct { name: [*:0]const u8 };
extern "c" fn getpwuid(uid: c_uint) ?*const NameRec;
extern "c" fn getgrgid(gid: c_uint) ?*const NameRec;

const specs = [_]common.OptSpec{
    .{ .id = '1', .short = '1' },
    .{ .id = 'a', .short = 'a', .long = "all" },
    .{ .id = 'A', .short = 'A', .long = "almost-all" },
    .{ .id = 'l', .short = 'l' },
    .{ .id = 'h', .short = 'h', .long = "human-readable" },
    .{ .id = 'R', .short = 'R', .long = "recursive" },
    .{ .id = 'd', .short = 'd', .long = "directory" },
    .{ .id = 'F', .short = 'F', .long = "classify" },
    .{ .id = 'p', .short = 'p' },
    .{ .id = 't', .short = 't' },
    .{ .id = 'S', .short = 'S' },
    .{ .id = 'U', .short = 'U' },
    .{ .id = 'r', .short = 'r', .long = "reverse" },
    .{ .id = 'n', .short = 'n', .long = "numeric-uid-gid" },
    .{ .id = 'c', .long = "color", .arg = .optional },
    .{ .id = 'o', .long = "sort", .arg = .required },
};

const Ignore = enum { default, dot_dotdot, minimal };
const SortKey = enum { name, time, size, none };
const Ind = enum { none, slash, classify };

const Cfg = struct {
    ignore: Ignore = .default,
    long: bool = false,
    human: bool = false,
    numeric: bool = false,
    recursive: bool = false,
    dirs: bool = false,
    ind: Ind = .none,
    sort: SortKey = .name,
    reverse: bool = false,
};

fn parseOpts(argv: []const []const u8, err: ?*Io.Writer, alloc: std.mem.Allocator, operands: ?*std.ArrayList([]const u8)) ?Cfg {
    var cfg: Cfg = .{};
    var p = common.Parser.init(argv, &specs, err);
    while (true) {
        const it = (p.next() catch return null) orelse break;
        switch (it) {
            .operand => |o| if (operands) |l| l.append(alloc, o) catch return null,
            .opt => |m| switch (m.id) {
                '1' => {},
                'a' => cfg.ignore = .minimal,
                'A' => cfg.ignore = .dot_dotdot,
                'l' => cfg.long = true,
                'n' => {
                    cfg.long = true;
                    cfg.numeric = true;
                },
                'h' => cfg.human = true,
                'R' => cfg.recursive = true,
                'd' => cfg.dirs = true,
                'F' => cfg.ind = .classify,
                'p' => cfg.ind = .slash,
                't' => cfg.sort = .time,
                'S' => cfg.sort = .size,
                'U' => cfg.sort = .none,
                'r' => cfg.reverse = true,
                'c' => {
                    const a = m.arg orelse return null;
                    if (!std.mem.eql(u8, a, "never") and !std.mem.eql(u8, a, "no") and !std.mem.eql(u8, a, "none")) return null;
                },
                'o' => {
                    const a = m.arg.?;
                    if (std.mem.eql(u8, a, "time")) {
                        cfg.sort = .time;
                    } else if (std.mem.eql(u8, a, "size")) {
                        cfg.sort = .size;
                    } else if (std.mem.eql(u8, a, "none")) {
                        cfg.sort = .none;
                    } else return null;
                },
                else => unreachable,
            },
        }
    }
    return cfg;
}

pub fn supports(argv: []const []const u8) bool {
    return parseOpts(argv, null, std.heap.page_allocator, null) != null;
}

const env_blockers = [_][]const u8{ "QUOTING_STYLE", "TIME_STYLE", "LS_BLOCK_SIZE", "BLOCK_SIZE", "BLOCKSIZE", "POSIXLY_CORRECT" };

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    const cfg = parseOpts(argv, null, std.heap.page_allocator, null) orelse return false;
    if (!common.localeIsCLike(env, "LC_COLLATE")) return false;
    for (env_blockers) |k| if (env.get(k)) |v| if (v.len > 0) return false;
    if (cfg.long) {
        if (!common.localeIsCLike(env, "LC_TIME") or !common.localeIsCLike(env, "LC_NUMERIC")) return false;
        if (!fsx.utcOffsetZero(env)) return false;
    }
    return true;
}

const Ent = struct {
    name: []const u8,
    full: []const u8,
    ty: u16 = 0,
    st: ?fsx.St = null,
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

const Ls = struct {
    ctx: *Ctx,
    io: Stdio,
    cfg: Cfg,
    prog: []const u8,
    status: u8 = 0,
    print_dir_name: bool = true,
    first_dir: bool = true,
    now_s: i64 = 0,
    now_ns: u32 = 0,
    users: std.AutoHashMap(u32, []const u8),
    groups: std.AutoHashMap(u32, []const u8),

    fn fail(self: *Ls, serious: bool) void {
        if (serious) {
            self.status = 2;
        } else if (self.status == 0) self.status = 1;
    }

    fn report(self: *Ls, pre: []const u8, name: []const u8, reason: []const u8) void {
        self.io.out.flush() catch {};
        common.fileErrReason(self.ctx, self.io, self.prog, pre, name, true, "", reason);
    }

    fn needStat(self: *const Ls) bool {
        return self.cfg.long or self.cfg.sort == .time or self.cfg.sort == .size;
    }

    fn ensureStat(self: *Ls, e: *Ent) void {
        if (e.st != null) return;
        e.st = fsx.stat(self.ctx, e.full, false) catch null;
    }

    fn less(self: *const Ls, a: Ent, b: Ent) bool {
        var ord: std.math.Order = .eq;
        switch (self.cfg.sort) {
            .time => {
                const x = a.st.?;
                const y = b.st.?;
                if (x.mtime_s != y.mtime_s) {
                    ord = std.math.order(y.mtime_s, x.mtime_s);
                } else ord = std.math.order(y.mtime_ns, x.mtime_ns);
            },
            .size => ord = std.math.order(b.st.?.size, a.st.?.size),
            else => {},
        }
        if (ord == .eq) ord = std.mem.order(u8, a.name, b.name);
        if (self.cfg.reverse) return ord == .gt;
        return ord == .lt;
    }

    fn sortEnts(self: *const Ls, ents: []Ent) void {
        if (self.cfg.sort == .none) return;
        std.mem.sort(Ent, ents, self, less);
    }

    fn indicator(self: *Ls, mode_fmt: u16, mode: u16) u8 {
        if (self.cfg.ind == .none) return 0;
        switch (mode_fmt) {
            fsx.S_IFDIR => return '/',
            else => {},
        }
        if (self.cfg.ind == .slash) return 0;
        return switch (mode_fmt) {
            fsx.S_IFLNK => '@',
            fsx.S_IFIFO => '|',
            fsx.S_IFSOCK => '=',
            fsx.S_IFREG => if (mode & 0o111 != 0) '*' else 0,
            else => 0,
        };
    }

    fn entIndicator(self: *Ls, e: *Ent) u8 {
        if (self.cfg.ind == .none) return 0;
        if (e.ty == fsx.S_IFREG and self.cfg.ind == .classify) {
            self.ensureStat(e);
            return self.indicator(e.ty, if (e.st) |s| s.mode else 0);
        }
        return self.indicator(e.ty, 0);
    }

    const Named = struct { s: []const u8, num: bool };

    fn lookupName(self: *Ls, a: std.mem.Allocator, id: u32, is_user: bool) !Named {
        if (!self.cfg.numeric) {
            const map = if (is_user) &self.users else &self.groups;
            if (map.get(id)) |n| return .{ .s = n, .num = false };
            const rec = if (is_user) getpwuid(id) else getgrgid(id);
            if (rec) |r| {
                const n = try self.ctx.alloc.dupe(u8, std.mem.span(r.name));
                try map.put(id, n);
                return .{ .s = n, .num = false };
            }
        }
        return .{ .s = try std.fmt.allocPrint(a, "{d}", .{id}), .num = true };
    }

    fn printShort(self: *Ls, ents: []Ent) !void {
        const w = self.io.out;
        for (ents) |*e| {
            try common.put(w, e.name);
            const c = self.entIndicator(e);
            if (c != 0) try common.putByte(w, c);
            try common.putByte(w, '\n');
        }
    }

    const Row = struct {
        mark: u8 = ' ',
        owner_num: bool = false,
        group_num: bool = false,
        owner: []const u8 = "",
        group: []const u8 = "",
        size: []const u8 = "",
        major: u32 = 0,
        minor: u32 = 0,
        dev: bool = false,
        link: []const u8 = "",
        link_ind: u8 = 0,
        has_link: bool = false,
    };

    fn printLong(self: *Ls, a: std.mem.Allocator, ents: []Ent, with_total: bool, skip_dirs: bool) !void {
        const w = self.io.out;
        const rows = try a.alloc(Row, ents.len);
        var any_mark = false;
        var total_blocks: u64 = 0;
        var nlink_w: usize = 0;
        var owner_w: usize = 0;
        var group_w: usize = 0;
        var size_w: usize = 0;
        var major_w: usize = 0;
        var minor_w: usize = 0;
        var any_dev = false;
        for (ents, rows) |*e, *r| {
            r.* = .{};
            const st = e.st.?;
            total_blocks += st.blocks;
            const un = try self.lookupName(a, st.uid, true);
            const gn = try self.lookupName(a, st.gid, false);
            r.owner = un.s;
            r.group = gn.s;
            r.owner_num = un.num;
            r.group_num = gn.num;
            owner_w = @max(owner_w, r.owner.len);
            group_w = @max(group_w, r.group.len);
            nlink_w = @max(nlink_w, digits(st.nlink));
            const fmt_ = st.fmt();
            if (fmt_ == fsx.S_IFCHR or fmt_ == fsx.S_IFBLK) {
                r.dev = true;
                any_dev = true;
                r.major = st.rdev_major;
                r.minor = st.rdev_minor;
                major_w = @max(major_w, digits(r.major));
                minor_w = @max(minor_w, digits(r.minor));
            } else {
                r.size = try self.sizeStr(a, st.size);
                size_w = @max(size_w, r.size.len);
            }
            if (fmt_ != fsx.S_IFLNK) {
                switch (fsx.xattrMark(self.ctx, e.full)) {
                    .acl => r.mark = '+',
                    .context => if (selinuxEnabled()) {
                        r.mark = '.';
                    },
                    .none => {},
                }
                if (r.mark != ' ') any_mark = true;
            }
            if (fmt_ == fsx.S_IFLNK) {
                var lb: [common.path_max]u8 = undefined;
                if (fsx.readlink(self.ctx, e.full, &lb)) |t| {
                    r.link = try a.dupe(u8, t);
                    r.has_link = true;
                    if (self.cfg.ind != .none) {
                        if (fsx.stat(self.ctx, e.full, true)) |ts| {
                            r.link_ind = self.indicator(ts.fmt(), ts.mode);
                        } else |_| {}
                    }
                } else |_| {}
            }
        }
        if (any_dev) size_w = @max(size_w, major_w + 2 + minor_w);
        if (with_total) {
            try common.put(w, "total ");
            if (self.cfg.human) {
                try common.put(w, try self.humanStr(a, total_blocks * 512));
            } else try common.putUint(w, (total_blocks + 1) / 2);
            try common.putByte(w, '\n');
        }
        for (ents, rows) |*e, *r| {
            if (skip_dirs and e.ty == fsx.S_IFDIR) continue;
            const st = e.st.?;
            var mb: [10]u8 = undefined;
            modeStr(&mb, st.mode);
            try common.put(w, &mb);
            if (any_mark) try common.putByte(w, r.mark);
            try common.putByte(w, ' ');
            try common.putUintPad(w, st.nlink, nlink_w);
            try common.putByte(w, ' ');
            if (r.owner_num) try padLeft(w, r.owner, owner_w) else try padRight(w, r.owner, owner_w);
            try common.putByte(w, ' ');
            if (r.group_num) try padLeft(w, r.group, group_w) else try padRight(w, r.group, group_w);
            try common.putByte(w, ' ');
            if (r.dev) {
                const blanks = size_w - (major_w + 2 + minor_w);
                try common.putUintPad(w, r.major, major_w + blanks);
                try common.put(w, ", ");
                try common.putUintPad(w, r.minor, minor_w);
            } else try padLeft(w, r.size, size_w);
            try common.putByte(w, ' ');
            try self.putDate(w, st.mtime_s, st.mtime_ns);
            try common.putByte(w, ' ');
            try common.put(w, e.name);
            if (st.fmt() == fsx.S_IFLNK) {
                if (r.has_link) {
                    try common.put(w, " -> ");
                    try common.put(w, r.link);
                    if (r.link_ind != 0) try common.putByte(w, r.link_ind);
                }
            } else {
                const c = self.indicator(st.fmt(), st.mode);
                if (c != 0) try common.putByte(w, c);
            }
            try common.putByte(w, '\n');
        }
    }

    fn sizeStr(self: *Ls, a: std.mem.Allocator, n: u64) ![]const u8 {
        if (self.cfg.human) return self.humanStr(a, n);
        return std.fmt.allocPrint(a, "{d}", .{n});
    }

    fn humanStr(_: *Ls, a: std.mem.Allocator, n: u64) ![]const u8 {
        if (n < 1024) return std.fmt.allocPrint(a, "{d}", .{n});
        const suffix = "KMGTPEZY";
        var e: usize = 1;
        var pw: u128 = 1024;
        while (e < suffix.len and @as(u128, n) >= pw * 1024) {
            e += 1;
            pw *= 1024;
        }
        while (true) {
            const tenths: u128 = (@as(u128, n) * 10 + pw - 1) / pw;
            if (tenths < 100) return std.fmt.allocPrint(a, "{d}.{d}{c}", .{ tenths / 10, tenths % 10, suffix[e - 1] });
            const whole: u128 = (@as(u128, n) + pw - 1) / pw;
            if (whole >= 1024 and e < suffix.len) {
                e += 1;
                pw *= 1024;
                continue;
            }
            return std.fmt.allocPrint(a, "{d}{c}", .{ whole, suffix[e - 1] });
        }
    }

    fn putDate(self: *Ls, w: *Io.Writer, s: i64, ns: u32) !void {
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const days: i64 = @divFloor(s, 86400);
        const secs: i64 = @mod(s, 86400);
        const z = days + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        var y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: usize = @intCast(if (mp < 10) mp + 3 else mp - 9);
        if (m <= 2) y += 1;
        const past = self.now_s - 15778476;
        const newer_than_past = s > past or (s == past and ns > self.now_ns);
        const older_than_now = s < self.now_s or (s == self.now_s and ns < self.now_ns);
        const recent = newer_than_past and older_than_now;
        try common.put(w, months[m - 1]);
        try common.putByte(w, ' ');
        if (d < 10) try common.putByte(w, ' ');
        try common.putUint(w, @intCast(d));
        if (recent) {
            try common.putByte(w, ' ');
            const hh: u8 = @intCast(@divFloor(secs, 3600));
            const mm: u8 = @intCast(@divFloor(@mod(secs, 3600), 60));
            try common.put(w, &.{ '0' + hh / 10, '0' + hh % 10, ':', '0' + mm / 10, '0' + mm % 10 });
        } else {
            try common.put(w, "  ");
            try common.putUint(w, @intCast(y));
        }
    }

    fn printEntries(self: *Ls, a: std.mem.Allocator, ents: []Ent, with_total: bool) !void {
        if (self.cfg.long) return self.printLong(a, ents, with_total, false);
        return self.printShort(ents);
    }

    fn makeEnt(self: *Ls, a: std.mem.Allocator, dirpath: []const u8, name: []const u8, kind: Io.File.Kind) !?Ent {
        const full = try fsx.joinChild(a, dirpath, name);
        var e: Ent = .{ .name = name, .full = full, .ty = kindBits(kind) };
        if (self.needStat() or e.ty == 0) {
            const st = fsx.stat(self.ctx, full, false) catch |err| {
                self.report("cannot access ", full, fsx.errText(err));
                self.fail(false);
                return null;
            };
            e.st = st;
            e.ty = st.fmt();
        }
        return e;
    }

    fn printDir(self: *Ls, path: []const u8, cmdline: bool) common.IoError!void {
        var dl = common.readDirList(self.ctx, path) catch |err| {
            self.report("cannot open directory ", path, common.errnoText(err));
            self.fail(cmdline);
            return;
        };
        defer dl.deinit(self.ctx.alloc);
        if (self.cfg.recursive or self.print_dir_name) {
            if (!self.first_dir) try common.putByte(self.io.out, '\n');
            self.first_dir = false;
            try common.put(self.io.out, path);
            try common.put(self.io.out, ":\n");
        }
        var arena = std.heap.ArenaAllocator.init(self.ctx.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var ents: std.ArrayList(Ent) = .empty;
        if (self.cfg.ignore == .minimal) {
            for ([_][]const u8{ ".", ".." }) |n| {
                if (try self.makeEnt(a, path, n, .directory)) |e| try ents.append(a, e);
            }
        }
        for (dl.items.items) |de| {
            if (self.cfg.ignore == .default and de.name.len > 0 and de.name[0] == '.') continue;
            if (try self.makeEnt(a, path, de.name, de.kind)) |e| try ents.append(a, e);
        }
        self.sortEnts(ents.items);
        try self.printEntries(a, ents.items, self.cfg.long);
        if (self.cfg.recursive) {
            for (ents.items) |e| {
                if (e.ty != fsx.S_IFDIR) continue;
                if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
                try self.printDir(e.full, false);
            }
        }
    }

    fn run(self: *Ls, operands: []const []const u8) !void {
        const a = self.ctx.alloc;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        const ops: []const []const u8 = if (operands.len == 0) &.{"."} else operands;
        const deref = !(self.cfg.dirs or self.cfg.ind == .classify or self.cfg.long);
        var all: std.ArrayList(Ent) = .empty;
        for (ops) |op| {
            var st: fsx.St = undefined;
            if (deref) {
                if (fsx.stat(self.ctx, op, true)) |s| {
                    st = s;
                    if (!s.isDir()) st = fsx.stat(self.ctx, op, false) catch |err| {
                        self.operandFail(op, err);
                        continue;
                    };
                } else |err| {
                    if (err != error.NoEnt) {
                        self.operandFail(op, err);
                        continue;
                    }
                    st = fsx.stat(self.ctx, op, false) catch |e2| {
                        self.operandFail(op, e2);
                        continue;
                    };
                }
            } else {
                st = fsx.stat(self.ctx, op, false) catch |err| {
                    self.operandFail(op, err);
                    continue;
                };
            }
            try all.append(ar, .{ .name = op, .full = op, .ty = st.fmt(), .st = st });
        }
        self.sortEnts(all.items);
        var files: std.ArrayList(Ent) = .empty;
        var dirs: std.ArrayList(Ent) = .empty;
        for (all.items) |e| {
            if (e.ty == fsx.S_IFDIR and !self.cfg.dirs) {
                try dirs.append(ar, e);
            } else try files.append(ar, e);
        }
        if (files.items.len > 0) {
            if (self.cfg.long) {
                try self.printLong(ar, all.items, false, !self.cfg.dirs);
            } else try self.printShort(files.items);
            if (dirs.items.len > 0) try common.putByte(self.io.out, '\n');
        } else if (ops.len <= 1 and dirs.items.len == 1) self.print_dir_name = false;
        for (dirs.items) |d| try self.printDir(d.full, true);
    }

    fn operandFail(self: *Ls, op: []const u8, err: fsx.Error) void {
        self.report("cannot access ", op, fsx.errText(err));
        self.fail(true);
    }
};

fn digits(n: u64) usize {
    var v = n;
    var c: usize = 1;
    while (v >= 10) : (v /= 10) c += 1;
    return c;
}

fn padLeft(w: *Io.Writer, s: []const u8, width: usize) !void {
    var i = s.len;
    while (i < width) : (i += 1) try common.putByte(w, ' ');
    try common.put(w, s);
}

fn padRight(w: *Io.Writer, s: []const u8, width: usize) !void {
    try common.put(w, s);
    var i = s.len;
    while (i < width) : (i += 1) try common.putByte(w, ' ');
}

fn modeStr(b: *[10]u8, mode: u16) void {
    b[0] = switch (mode & fsx.S_IFMT) {
        fsx.S_IFDIR => 'd',
        fsx.S_IFLNK => 'l',
        fsx.S_IFIFO => 'p',
        fsx.S_IFSOCK => 's',
        fsx.S_IFBLK => 'b',
        fsx.S_IFCHR => 'c',
        else => '-',
    };
    const rwx = "rwxrwxrwx";
    for (0..9) |i| {
        const bit: u16 = @as(u16, 1) << @intCast(8 - i);
        b[1 + i] = if (mode & bit != 0) rwx[i] else '-';
    }
    if (mode & 0o4000 != 0) b[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) b[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) b[9] = if (mode & 0o001 != 0) 't' else 'T';
}

var selinux_cache: ?bool = null;

fn selinuxEnabled() bool {
    if (selinux_cache) |c| return c;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, "/sys/fs/selinux/enforce", 0, .{ .TYPE = true }, &sx);
    const r = linux.errno(rc) == .SUCCESS;
    selinux_cache = r;
    return r;
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, argv[0], io);
}

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) !u8 {
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.alloc);
    const cfg = parseOpts(argv, io.err, ctx.alloc, &operands) orelse return 2;
    var ls: Ls = .{
        .ctx = ctx,
        .io = io,
        .cfg = cfg,
        .prog = argv[0],
        .users = std.AutoHashMap(u32, []const u8).init(ctx.alloc),
        .groups = std.AutoHashMap(u32, []const u8).init(ctx.alloc),
    };
    defer {
        var it = ls.users.valueIterator();
        while (it.next()) |v| ctx.alloc.free(v.*);
        ls.users.deinit();
        var it2 = ls.groups.valueIterator();
        while (it2.next()) |v| ctx.alloc.free(v.*);
        ls.groups.deinit();
    }
    if (cfg.long) {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        ls.now_s = ts.sec;
        ls.now_ns = @intCast(ts.nsec);
    }
    try ls.run(operands.items);
    try io.out.flush();
    return ls.status;
}

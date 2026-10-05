const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");

pub const Error = error{ NoEnt, Access, NotDir, Loop, NameTooLong, NoMem, Other };

pub fn errText(e: Error) []const u8 {
    return switch (e) {
        error.NoEnt => "No such file or directory",
        error.Access => "Permission denied",
        error.NotDir => "Not a directory",
        error.Loop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        error.NoMem => "Cannot allocate memory",
        error.Other => "Input/output error",
    };
}

fn mapErr(rc: usize) Error {
    return switch (linux.errno(rc)) {
        .NOENT => error.NoEnt,
        .ACCES, .PERM => error.Access,
        .NOTDIR => error.NotDir,
        .LOOP => error.Loop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.NoMem,
        else => error.Other,
    };
}

pub const S_IFMT: u16 = 0o170000;
pub const S_IFSOCK: u16 = 0o140000;
pub const S_IFLNK: u16 = 0o120000;
pub const S_IFREG: u16 = 0o100000;
pub const S_IFBLK: u16 = 0o060000;
pub const S_IFDIR: u16 = 0o040000;
pub const S_IFCHR: u16 = 0o020000;
pub const S_IFIFO: u16 = 0o010000;

pub const St = struct {
    mode: u16,
    nlink: u32,
    uid: u32,
    gid: u32,
    size: u64,
    blocks: u64,
    ino: u64,
    mtime_s: i64,
    mtime_ns: u32,
    rdev_major: u32,
    rdev_minor: u32,

    pub fn fmt(self: St) u16 {
        return self.mode & S_IFMT;
    }
    pub fn isDir(self: St) bool {
        return self.fmt() == S_IFDIR;
    }
    pub fn isLnk(self: St) bool {
        return self.fmt() == S_IFLNK;
    }
    pub fn isReg(self: St) bool {
        return self.fmt() == S_IFREG;
    }
    pub fn newerThan(self: St, s: i64, ns: u32) bool {
        if (self.mtime_s != s) return self.mtime_s > s;
        return self.mtime_ns > ns;
    }
};

pub const PathBuf = struct {
    pb: [common.path_max]u8 = undefined,
    zb: [common.path_max + 1]u8 = undefined,

    pub fn z(self: *PathBuf, ctx: *common.Ctx, path: []const u8) Error![:0]const u8 {
        if (path.len == 0) return error.NoEnt;
        const full = common.joinCwd(&self.pb, ctx.cwd, path) catch return error.NameTooLong;
        if (full.len > common.path_max) return error.NameTooLong;
        @memcpy(self.zb[0..full.len], full);
        self.zb[full.len] = 0;
        return self.zb[0..full.len :0];
    }
};

pub fn stat(ctx: *common.Ctx, path: []const u8, follow: bool) Error!St {
    var pbuf: PathBuf = undefined;
    const zp = try pbuf.z(ctx, path);
    var sx: linux.Statx = undefined;
    const flags: u32 = @as(u32, linux.AT.NO_AUTOMOUNT) | @as(u32, if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW);
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .MTIME = true, .INO = true, .SIZE = true, .BLOCKS = true };
    const rc = linux.statx(linux.AT.FDCWD, zp.ptr, flags, mask, &sx);
    if (linux.errno(rc) != .SUCCESS) return mapErr(rc);
    return .{
        .mode = sx.mode,
        .nlink = sx.nlink,
        .uid = sx.uid,
        .gid = sx.gid,
        .size = sx.size,
        .blocks = sx.blocks,
        .ino = sx.ino,
        .mtime_s = sx.mtime.sec,
        .mtime_ns = sx.mtime.nsec,
        .rdev_major = sx.rdev_major,
        .rdev_minor = sx.rdev_minor,
    };
}

pub fn readlink(ctx: *common.Ctx, path: []const u8, out: []u8) Error![]const u8 {
    var pbuf: PathBuf = undefined;
    const zp = try pbuf.z(ctx, path);
    const rc = linux.readlink(zp.ptr, out.ptr, out.len);
    if (linux.errno(rc) != .SUCCESS) return mapErr(rc);
    return out[0..rc];
}

pub const XattrMark = enum { none, acl, context };

pub fn xattrMark(ctx: *common.Ctx, path: []const u8) XattrMark {
    var pbuf: PathBuf = undefined;
    const zp = pbuf.z(ctx, path) catch return .none;
    var buf: [512]u8 = undefined;
    const rc = linux.llistxattr(zp.ptr, &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return .none;
    var mark: XattrMark = .none;
    var it = std.mem.splitScalar(u8, buf[0..rc], 0);
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, "system.posix_acl_access") or std.mem.eql(u8, name, "system.posix_acl_default")) return .acl;
        if (std.mem.eql(u8, name, "security.selinux") or std.mem.eql(u8, name, "security.SMACK64")) mark = .context;
    }
    return mark;
}

pub fn joinChild(alloc: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    const trim = parent.len > 0 and parent[parent.len - 1] == '/';
    const base = if (trim) parent[0 .. parent.len - 1] else parent;
    const out = try alloc.alloc(u8, base.len + 1 + name.len);
    @memcpy(out[0..base.len], base);
    out[base.len] = '/';
    @memcpy(out[base.len + 1 ..], name);
    return out;
}

pub fn utcOffsetZero(env: *const common.EnvView) bool {
    if (env.get("TZ")) |tz| {
        const t = if (tz.len > 0 and tz[0] == ':') tz[1..] else tz;
        const names = [_][]const u8{ "", "UTC", "UTC0", "GMT", "GMT0", "Etc/UTC", "Etc/GMT", "UCT", "Zulu", "Universal" };
        for (names) |n| if (std.mem.eql(u8, t, n)) return true;
        return false;
    }
    return localtimeIsUtc();
}

var localtime_cache: ?bool = null;

fn localtimeIsUtc() bool {
    if (localtime_cache) |c| return c;
    var buf: [256]u8 = undefined;
    const rc = linux.readlink("/etc/localtime", &buf, buf.len);
    const r: bool = switch (linux.errno(rc)) {
        .SUCCESS => blk: {
            const t = buf[0..rc];
            const names = [_][]const u8{ "/UTC", "/Etc/UTC", "/UCT", "/Etc/UCT", "/Zulu", "/Universal", "/GMT", "/Etc/GMT" };
            for (names) |n| if (std.mem.endsWith(u8, t, n)) break :blk true;
            break :blk false;
        },
        .NOENT => true,
        else => false,
    };
    localtime_cache = r;
    return r;
}

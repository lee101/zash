const std = @import("std");
const sys = @import("sys.zig");

const FileActions = extern struct { buf: [128]u8 align(16) = undefined };
const Attr = extern struct { buf: [512]u8 align(16) = undefined };

extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, fa: *const FileActions, attr: *const Attr, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(fa: *FileActions, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(fa: *FileActions, fd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn posix_spawnattr_init(a: *Attr) c_int;
extern "c" fn posix_spawnattr_destroy(a: *Attr) c_int;
extern "c" fn posix_spawnattr_setflags(a: *Attr, flags: c_short) c_int;
extern "c" fn posix_spawnattr_setsigmask(a: *Attr, set: *const sys.SigSet) c_int;
extern "c" fn posix_spawnattr_setsigdefault(a: *Attr, set: *const sys.SigSet) c_int;

const SETSIGDEF: c_short = 0x04;
const SETSIGMASK: c_short = 0x08;

pub const Spawn = struct {
    fa: FileActions = .{},
    attr: Attr = .{},
    ok: bool = false,

    pub fn init(self: *Spawn, default_sigpipe: bool) bool {
        if (posix_spawn_file_actions_init(&self.fa) != 0) return false;
        if (posix_spawnattr_init(&self.attr) != 0) {
            _ = posix_spawn_file_actions_destroy(&self.fa);
            return false;
        }
        var mask: sys.SigSet = .{};
        _ = sys.sigemptyset(&mask);
        _ = posix_spawnattr_setsigmask(&self.attr, &mask);
        var flags: c_short = SETSIGMASK;
        if (default_sigpipe) {
            var def: sys.SigSet = .{};
            _ = sys.sigemptyset(&def);
            _ = sys.sigaddset(&def, sys.SIGPIPE);
            _ = posix_spawnattr_setsigdefault(&self.attr, &def);
            flags |= SETSIGDEF;
        }
        _ = posix_spawnattr_setflags(&self.attr, flags);
        self.ok = true;
        return true;
    }

    pub fn deinit(self: *Spawn) void {
        if (!self.ok) return;
        _ = posix_spawn_file_actions_destroy(&self.fa);
        _ = posix_spawnattr_destroy(&self.attr);
        self.ok = false;
    }

    pub fn dup2(self: *Spawn, from: c_int, to: c_int) bool {
        return posix_spawn_file_actions_adddup2(&self.fa, from, to) == 0;
    }

    pub fn open(self: *Spawn, fd: c_int, path: [*:0]const u8, flags: c_int) bool {
        return posix_spawn_file_actions_addopen(&self.fa, fd, path, flags, 0o666) == 0;
    }

    pub fn go(self: *Spawn, pid: *c_int, path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int {
        return posix_spawn(pid, path, &self.fa, &self.attr, argv, envp);
    }
};

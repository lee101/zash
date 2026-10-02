const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const vars_mod = @import("vars.zig");
const exec = @import("exec.zig");

pub const Shell = shell.Shell;
pub const Err = shell.Err;

var orig_stack: sys.RLimit = .{ .cur = 0, .max = 0 };

pub fn restore_stack_limit() void {
    if (orig_stack.cur != 0) _ = sys.setrlimit(3, &orig_stack);
}

fn raise_stack_limit() void {
    var rl: sys.RLimit = undefined;
    if (sys.getrlimit(3, &rl) != 0) return;
    orig_stack = rl;
    const want: u64 = 1 << 30;
    if (rl.cur >= want) return;
    var nl = rl;
    nl.cur = if (rl.max < want) rl.max else want;
    if (nl.cur > rl.cur) _ = sys.setrlimit(3, &nl);
}

fn set_special(sh: *Shell, name: []const u8, sp: vars_mod.Special) Err!void {
    const v = try sh.vars.get_or_create(sh.gpa, name);
    v.special = sp;
}

fn set_plain(sh: *Shell, name: []const u8, value: []const u8) Err!void {
    const v = try sh.vars.get_or_create(sh.gpa, name);
    try sh.set_str_raw(v, value);
}

fn contains_icase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn setup(sh: *Shell, environ: []const ?[*:0]const u8, script_name: []const u8) Err!void {
    raise_stack_limit();
    const gpa = sh.gpa;
    var lc_all: ?[]const u8 = null;
    var lc_ctype: ?[]const u8 = null;
    var lang: ?[]const u8 = null;
    var shlvl: i64 = 0;
    for (environ) |e_opt| {
        const e = e_opt orelse break;
        const s = std.mem.span(e);
        const eq = std.mem.findScalar(u8, s, '=') orelse continue;
        const name = s[0..eq];
        const value = s[eq + 1 ..];
        if (!shell.Shell.is_valid_name(name)) continue;
        if (std.mem.eql(u8, name, "IFS") or std.mem.eql(u8, name, "SHELLOPTS") or std.mem.eql(u8, name, "BASHOPTS") or std.mem.eql(u8, name, "UID") or std.mem.eql(u8, name, "EUID") or std.mem.eql(u8, name, "PPID")) continue;
        if (std.mem.eql(u8, name, "LC_ALL")) lc_all = value;
        if (std.mem.eql(u8, name, "LC_CTYPE")) lc_ctype = value;
        if (std.mem.eql(u8, name, "LANG")) lang = value;
        if (std.mem.eql(u8, name, "SHLVL")) shlvl = std.fmt.parseInt(i64, value, 10) catch 0;
        const v = try sh.vars.get_or_create(gpa, name);
        try sh.set_str_raw(v, value);
        v.flags.exported = true;
    }
    const loc = lc_all orelse lc_ctype orelse lang orelse "";
    sh.utf8 = contains_icase(loc, "utf-8") or contains_icase(loc, "utf8");
    sh.script_name = try gpa.dupe(u8, script_name);
    sh.cur_file = sh.script_name;
    try set_plain(sh, "IFS", " \t\n");
    if (sh.vars.get("PATH") == null) try set_plain(sh, "PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    try set_plain(sh, "PS1", "\\s-\\v\\$ ");
    try set_plain(sh, "PS2", "> ");
    try set_plain(sh, "PS4", "+ ");
    try set_plain(sh, "OPTIND", "1");
    sh.getopts_expect = 1;
    const shl = try std.fmt.allocPrint(sh.sa, "{d}", .{shlvl + 1});
    try set_plain(sh, "SHLVL", shl);
    sh.vars.get("SHLVL").?.flags.exported = true;
    const uid = try std.fmt.allocPrint(sh.sa, "{d}", .{sys.getuid()});
    try set_plain(sh, "UID", uid);
    sh.vars.get("UID").?.flags.readonly = true;
    sh.vars.get("UID").?.flags.integer = true;
    const euid = try std.fmt.allocPrint(sh.sa, "{d}", .{sys.geteuid()});
    try set_plain(sh, "EUID", euid);
    sh.vars.get("EUID").?.flags.readonly = true;
    sh.vars.get("EUID").?.flags.integer = true;
    const ppid = try std.fmt.allocPrint(sh.sa, "{d}", .{sys.getppid()});
    try set_plain(sh, "PPID", ppid);
    sh.vars.get("PPID").?.flags.readonly = true;
    sh.vars.get("PPID").?.flags.integer = true;
    try set_plain(sh, "BASH_VERSION", "5.1.16(1)-release");
    try set_plain(sh, "OSTYPE", "linux-gnu");
    try set_plain(sh, "HOSTTYPE", "x86_64");
    try set_plain(sh, "MACHTYPE", "x86_64-pc-linux-gnu");
    try set_plain(sh, "BASH", "/usr/bin/bash");
    var hb: [256]u8 = undefined;
    if (sys.gethostname(&hb, hb.len) == 0) {
        const hn = std.mem.sliceTo(&hb, 0);
        try set_plain(sh, "HOSTNAME", hn);
    }
    const bv = try sh.vars.get_or_create(gpa, "BASH_VERSINFO");
    try sh.declare_indexed(bv);
    const vi = [_][]const u8{ "5", "1", "16", "1", "release", "x86_64-pc-linux-gnu" };
    for (vi, 0..) |s, i| try sh.assign_indexed(bv, @intCast(i), s, false);
    bv.flags.readonly = true;
    try set_special(sh, "RANDOM", .random);
    try set_special(sh, "LINENO", .lineno);
    try set_special(sh, "SECONDS", .seconds);
    try set_special(sh, "BASHPID", .bashpid);
    try set_special(sh, "EPOCHSECONDS", .epochseconds);
    try set_special(sh, "EPOCHREALTIME", .epochrealtime);
    try set_special(sh, "SRANDOM", .srandom);
    sh.start_wall_ns = sys.now_ns();
    var cwd_buf: [4096]u8 = undefined;
    const have_cwd = sys.getcwd(&cwd_buf, cwd_buf.len);
    var pwd_ok = false;
    if (sh.vars.get("PWD")) |pv| {
        if (pv.value == .str and pv.value.str.len > 0 and pv.value.str[0] == '/') {
            const a = sys.stat_path(pv.value.str, true);
            const b = sys.stat_path(".", true);
            if (a != null and b != null and a.?.ino == b.?.ino and a.?.dev == b.?.dev) pwd_ok = true;
        }
    }
    if (!pwd_ok) {
        if (have_cwd) |p| {
            const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(p)), 0);
            try set_plain(sh, "PWD", cwd);
        }
    }
    if (sh.vars.get("PWD")) |pv| {
        pv.flags.exported = true;
        if (pv.value == .str) try sh.set_cwd_logical(pv.value.str);
    }
    if (sh.vars.get("OLDPWD") == null) {
        const v = try sh.vars.get_or_create(gpa, "OLDPWD");
        v.flags.exported = true;
    }
    sh.mark_env();
}

pub fn install_signals(sh: *Shell) void {
    _ = sh;
    sys.set_signal(sys.SIGINT, sys.SIG_DFL);
}

fn line_start_offsets(a: std.mem.Allocator, src: []const u8) ![]usize {
    var offs: std.ArrayList(usize) = .empty;
    try offs.append(a, 0);
    for (src, 0..) |c, i| {
        if (c == '\n') try offs.append(a, i + 1);
    }
    return offs.items;
}

pub fn run_script(sh: *Shell, src: []const u8, label_prefix: []const u8) u8 {
    return run_script_inner(sh, src, label_prefix) catch |e| switch (e) {
        error.Exit => finish(sh, sh.exit_status_pending orelse sh.status),
        error.Abort => finish(sh, sh.status),
        error.OutOfMemory => 1,
        else => finish(sh, sh.status),
    };
}

fn run_script_inner(sh: *Shell, src: []const u8, label_prefix: []const u8) Err!u8 {
    var arena = try sh.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(sh.gpa);
    try sh.keep_arenas.append(sh.gpa, arena);
    const a = arena.allocator();
    var p = parser.Parser.init(a, src, .{});
    const res = p.parse_script();
    if (res) |list| {
        const st = try exec.run_top(sh, list, src);
        return finish(sh, st);
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            const err = p.lex.err.?;
            const offs = try line_start_offsets(a, src);
            var cut: usize = @min(@as(usize, err.line), offs.len);
            while (cut > 1) {
                cut -= 1;
                const prefix = src[0..offs[cut]];
                var p2 = parser.Parser.init(a, prefix, .{});
                if (p2.parse_script()) |list| {
                    _ = exec.run_top(sh, list, prefix) catch |ee| switch (ee) {
                        error.Exit => return finish(sh, sh.exit_status_pending orelse sh.status),
                        else => {},
                    };
                    break;
                } else |_| {}
            }
            var aw = std.Io.Writer.Allocating.init(sh.sa);
            err.write(&aw.writer, label_prefix) catch {};
            _ = sys.write_all(2, aw.written());
            return finish(sh, 2);
        },
    }
}

pub fn finish(sh: *Shell, status: u8) u8 {
    var st = status;
    sh.exit_status_pending = null;
    if (sh.trap_exit.kind == .cmd and !sh.trap_exit.inherited) {
        const cmd = sh.trap_exit.cmd;
        sh.trap_exit = .{};
        sh.status = st;
        exec.run_trap_text(sh, cmd, 0) catch |e| switch (e) {
            error.Exit => {
                st = sh.exit_status_pending orelse sh.status;
                return st;
            },
            else => {},
        };
        if (sh.exit_status_pending) |x| st = x;
    }
    return st;
}

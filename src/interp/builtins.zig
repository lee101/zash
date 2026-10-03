const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const exec = @import("exec.zig");
const expand = @import("expand.zig");
const arith = @import("arith.zig");
const strutil = @import("strutil.zig");
const signals = @import("signals.zig");
const pattern = @import("pattern.zig");
const unparse = @import("unparse.zig");
const bi_decl = @import("bi_decl.zig");
const bi_printf = @import("bi_printf.zig");
const bi_read = @import("bi_read.zig");
const bi_test = @import("bi_test.zig");
const registry = @import("../utils/registry.zig");
const Shell = shell.Shell;
const Err = shell.Err;

pub const read_line_fd = bi_read.read_line_fd;

pub const RunFn = *const fn (*Shell, []const []const u8) Err!u8;
pub const DeclFn = *const fn (*Shell, []const exec.DeclItem) Err!u8;

pub const Builtin = struct {
    run: RunFn,
    decl: ?DeclFn = null,
    special: bool = false,
};

fn decl_declare(sh: *Shell, items: []const exec.DeclItem) Err!u8 {
    return bi_decl.run(sh, .declare, items);
}
fn decl_local(sh: *Shell, items: []const exec.DeclItem) Err!u8 {
    return bi_decl.run(sh, .local, items);
}
fn decl_export(sh: *Shell, items: []const exec.DeclItem) Err!u8 {
    return bi_decl.run(sh, .exp, items);
}
fn decl_readonly(sh: *Shell, items: []const exec.DeclItem) Err!u8 {
    return bi_decl.run(sh, .readonly, items);
}

fn plain_decl(comptime f: DeclFn) RunFn {
    return struct {
        fn run(sh: *Shell, argv: []const []const u8) Err!u8 {
            const items = try sh.sa.alloc(exec.DeclItem, argv.len);
            for (argv, 0..) |a, i| items[i] = .{ .arg = a };
            return f(sh, items);
        }
    }.run;
}

const table = std.StaticStringMap(Builtin).initComptime(.{
    .{ ":", Builtin{ .run = bi_colon, .special = true } },
    .{ "true", Builtin{ .run = bi_true } },
    .{ "false", Builtin{ .run = bi_false } },
    .{ "echo", Builtin{ .run = bi_echo } },
    .{ "printf", Builtin{ .run = bi_printf.run } },
    .{ "pwd", Builtin{ .run = bi_pwd } },
    .{ "cd", Builtin{ .run = bi_cd } },
    .{ "exit", Builtin{ .run = bi_exit, .special = true } },
    .{ "logout", Builtin{ .run = bi_exit } },
    .{ "return", Builtin{ .run = bi_return, .special = true } },
    .{ "break", Builtin{ .run = bi_break, .special = true } },
    .{ "continue", Builtin{ .run = bi_continue, .special = true } },
    .{ "shift", Builtin{ .run = bi_shift, .special = true } },
    .{ "set", Builtin{ .run = bi_set, .special = true } },
    .{ "shopt", Builtin{ .run = bi_shopt } },
    .{ "unset", Builtin{ .run = bi_unset, .special = true } },
    .{ "export", Builtin{ .run = plain_decl(decl_export), .decl = decl_export, .special = true } },
    .{ "readonly", Builtin{ .run = plain_decl(decl_readonly), .decl = decl_readonly, .special = true } },
    .{ "declare", Builtin{ .run = plain_decl(decl_declare), .decl = decl_declare } },
    .{ "typeset", Builtin{ .run = plain_decl(decl_declare), .decl = decl_declare } },
    .{ "local", Builtin{ .run = plain_decl(decl_local), .decl = decl_local } },
    .{ "eval", Builtin{ .run = bi_eval, .special = true } },
    .{ "source", Builtin{ .run = bi_source } },
    .{ ".", Builtin{ .run = bi_source, .special = true } },
    .{ "exec", Builtin{ .run = bi_exec, .special = true } },
    .{ "command", Builtin{ .run = bi_command } },
    .{ "builtin", Builtin{ .run = bi_builtin } },
    .{ "type", Builtin{ .run = bi_type } },
    .{ "hash", Builtin{ .run = bi_hash } },
    .{ "alias", Builtin{ .run = bi_alias } },
    .{ "unalias", Builtin{ .run = bi_unalias } },
    .{ "trap", Builtin{ .run = bi_trap, .special = true } },
    .{ "wait", Builtin{ .run = bi_wait } },
    .{ "kill", Builtin{ .run = bi_kill } },
    .{ "jobs", Builtin{ .run = bi_jobs } },
    .{ "disown", Builtin{ .run = bi_disown } },
    .{ "fg", Builtin{ .run = bi_fg } },
    .{ "bg", Builtin{ .run = bi_fg } },
    .{ "umask", Builtin{ .run = bi_umask } },
    .{ "ulimit", Builtin{ .run = bi_ulimit } },
    .{ "times", Builtin{ .run = bi_times, .special = true } },
    .{ "read", Builtin{ .run = bi_read.run_read } },
    .{ "mapfile", Builtin{ .run = bi_read.run_mapfile } },
    .{ "readarray", Builtin{ .run = bi_read.run_mapfile } },
    .{ "getopts", Builtin{ .run = bi_getopts } },
    .{ "let", Builtin{ .run = bi_let } },
    .{ "test", Builtin{ .run = bi_test.run } },
    .{ "[", Builtin{ .run = bi_test.run } },
    .{ "pushd", Builtin{ .run = bi_pushd } },
    .{ "popd", Builtin{ .run = bi_popd } },
    .{ "dirs", Builtin{ .run = bi_dirs } },
    .{ "help", Builtin{ .run = bi_help } },
    .{ "history", Builtin{ .run = bi_history } },
    .{ "compgen", Builtin{ .run = bi_compgen } },
    .{ "complete", Builtin{ .run = bi_complete } },
    .{ "compopt", Builtin{ .run = bi_complete } },
    .{ "enable", Builtin{ .run = bi_enable } },
    .{ "caller", Builtin{ .run = bi_caller } },
    .{ "bind", Builtin{ .run = bi_true } },
    .{ "fc", Builtin{ .run = bi_true } },
    .{ "suspend", Builtin{ .run = bi_true } },
});

const help_lines = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".", ". filename [arguments]" },
    .{ "alias", "alias [-p] [name[=value] ... ]" },
    .{ "bg", "bg [job_spec ...]" },
    .{ "break", "break [n]" },
    .{ "builtin", "builtin [shell-builtin [arg ...]]" },
    .{ "caller", "caller [expr]" },
    .{ "cd", "cd [-L|[-P [-e]] [-@]] [dir]" },
    .{ "command", "command [-pVv] command [arg ...]" },
    .{ "compgen", "compgen [-abcdefgjksuv] [-o option] [-A action] [-G globpat] [-W wordlist]  [-F function] [-C command] [-X filterpat] [-P prefix] [-S suffix] [word]" },
    .{ "continue", "continue [n]" },
    .{ "declare", "declare [-aAfFgiIlnrtux] [name[=value] ...] or declare -p [-aAfFilnrtux] [name ...]" },
    .{ "dirs", "dirs [-clpv] [+N] [-N]" },
    .{ "disown", "disown [-h] [-ar] [jobspec ... | pid ...]" },
    .{ "enable", "enable [-a] [-dnps] [-f filename] [name ...]" },
    .{ "eval", "eval [arg ...]" },
    .{ "exec", "exec [-cl] [-a name] [command [argument ...]] [redirection ...]" },
    .{ "exit", "exit [n]" },
    .{ "export", "export [-fn] [name[=value] ...] or export -p" },
    .{ "fg", "fg [job_spec]" },
    .{ "getopts", "getopts optstring name [arg ...]" },
    .{ "hash", "hash [-lr] [-p pathname] [-dt] [name ...]" },
    .{ "help", "help [-dms] [pattern ...]" },
    .{ "history", "history [-c] [-d offset] [n] or history -anrw [filename] or history -ps arg [arg...]" },
    .{ "jobs", "jobs [-lnprs] [jobspec ...] or jobs -x command [args]" },
    .{ "kill", "kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]" },
    .{ "let", "let arg [arg ...]" },
    .{ "local", "local [option] name[=value] ..." },
    .{ "logout", "logout [n]" },
    .{ "mapfile", "mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]" },
    .{ "popd", "popd [-n] [+N | -N]" },
    .{ "printf", "printf [-v var] format [arguments]" },
    .{ "pushd", "pushd [-n] [+N | -N | dir]" },
    .{ "pwd", "pwd [-LP]" },
    .{ "read", "read [-ers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]" },
    .{ "readarray", "readarray [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]" },
    .{ "readonly", "readonly [-aAf] [name[=value] ...] or readonly -p" },
    .{ "return", "return [n]" },
    .{ "set", "set [-abefhkmnptuvxBCHP] [-o option-name] [--] [arg ...]" },
    .{ "shift", "shift [n]" },
    .{ "shopt", "shopt [-pqsu] [-o] [optname ...]" },
    .{ "source", "source filename [arguments]" },
    .{ "suspend", "suspend [-f]" },
    .{ "times", "times" },
    .{ "trap", "trap [-lp] [[arg] signal_spec ...]" },
    .{ "type", "type [-afptP] name [name ...]" },
    .{ "typeset", "typeset [-aAfFgiIlnrtux] name[=value] ... or typeset -p [-aAfFilnrtux] [name ...]" },
    .{ "ulimit", "ulimit [-SHabcdefiklmnpqrstuvxPT] [limit]" },
    .{ "umask", "umask [-p] [-S] [mode]" },
    .{ "unalias", "unalias [-a] name [name ...]" },
    .{ "unset", "unset [-f] [-v] [-n] [name ...]" },
    .{ "wait", "wait [-fn] [-p var] [id ...]" },
});

pub fn help_line(name: []const u8) ?[]const u8 {
    return help_lines.get(name);
}

pub fn lookup(name: []const u8) ?Builtin {
    if (sh_disabled_check(name)) return null;
    return table.get(name);
}

var disabled_buf: [64][]const u8 = undefined;
var disabled_n: usize = 0;

fn sh_disabled_check(name: []const u8) bool {
    for (disabled_buf[0..disabled_n]) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

pub fn is_builtin(name: []const u8) bool {
    return lookup(name) != null;
}

fn bi_colon(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = sh;
    _ = argv;
    return 0;
}
fn bi_true(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = sh;
    _ = argv;
    return 0;
}
fn bi_false(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = sh;
    _ = argv;
    return 1;
}

fn write_fail(sh: *Shell, name: []const u8) u8 {
    sh.bmsg(name, "write error: {s}", .{sys.msg_for(sys.errno())});
    return 1;
}

fn bi_echo(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var newline = true;
    var interp = sh.shopt(.xpg_echo);
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        var ok = true;
        for (a[1..]) |c| {
            if (c != 'n' and c != 'e' and c != 'E') {
                ok = false;
                break;
            }
        }
        if (!ok) break;
        for (a[1..]) |c| {
            switch (c) {
                'n' => newline = false,
                'e' => interp = true,
                'E' => interp = false,
                else => {},
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    const a = sh.sa;
    var stop = false;
    while (i < argv.len and !stop) : (i += 1) {
        if (out.items.len > 0 or i > 1 and out.capacity > 0) {}
        const s = argv[i];
        if (i > 1 and !(i == 1)) {}
        if (!interp) {
            try out.appendSlice(a, s);
        } else {
            var k: usize = 0;
            while (k < s.len) {
                if (s[k] == '\\' and k + 1 < s.len) {
                    if (s[k + 1] == 'c') {
                        stop = true;
                        newline = false;
                        break;
                    }
                    if (s[k + 1] >= '1' and s[k + 1] <= '7') {
                        try out.append(a, '\\');
                        k += 1;
                        continue;
                    }
                    if (s[k + 1] == '0') {
                        var v: u32 = 0;
                        var q = k + 2;
                        var cnt: usize = 0;
                        while (q < s.len and cnt < 3 and s[q] >= '0' and s[q] <= '7') : (q += 1) {
                            v = v * 8 + (s[q] - '0');
                            cnt += 1;
                        }
                        try out.append(a, @truncate(v));
                        k = q;
                        continue;
                    }
                    const r = try strutil.ansi_escape(a, &out, s, k + 1, false);
                    k += 1 + r.consumed;
                } else {
                    try out.append(a, s[k]);
                    k += 1;
                }
            }
        }
        if (!stop and i + 1 < argv.len) try out.append(a, ' ');
    }
    if (newline) try out.append(a, '\n');
    if (out.items.len > 0 and !sh.out(out.items)) return write_fail(sh, "echo");
    return 0;
}

fn canonical(sh: *Shell, path: []const u8) Err![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(sh.sa, p);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.append(sh.sa, '/');
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.append(sh.sa, '/');
        try out.appendSlice(sh.sa, p);
    }
    return out.items;
}

pub fn physical_cwd(sh: *Shell) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const p = sys.getcwd(&buf, buf.len) orelse return null;
    const s = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(p)), 0);
    return sh.sa.dupe(u8, s) catch null;
}

fn bi_pwd(sh: *Shell, argv: []const []const u8) Err!u8 {
    var physical = sh.opt(.physical);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (a.len < 2 or a[0] != '-') break;
        for (a[1..]) |c| {
            switch (c) {
                'L' => physical = false,
                'P' => physical = true,
                else => {
                    sh.bmsg("pwd", "-{c}: invalid option", .{c});
                    sh.usage_msg("pwd", "pwd [-LP]");
                    return 2;
                },
            }
        }
    }
    if (!physical and sh.cwd_logical.len > 0) {
        _ = sh.out(try std.mem.concat(sh.sa, u8, &.{ sh.cwd_logical, "\n" }));
        return 0;
    }
    const cwd = physical_cwd(sh) orelse {
        sh.bmsg("pwd", "error retrieving current directory: getcwd: cannot access parent directories: {s}", .{sys.msg_for(sys.errno())});
        return 1;
    };
    _ = sh.out(try std.mem.concat(sh.sa, u8, &.{ cwd, "\n" }));
    return 0;
}

pub fn do_chdir(sh: *Shell, who: []const u8, dir: []const u8, physical: bool, print_new: bool) Err!bool {
    var target: []const u8 = dir;
    var logical: ?[]const u8 = null;
    if (!physical) {
        const base: []const u8 = if (dir.len > 0 and dir[0] == '/') "" else (sh.get_scalar("PWD") orelse "");
        const joined = if (base.len > 0) try std.mem.concat(sh.sa, u8, &.{ base, "/", dir }) else dir;
        if (joined.len > 0 and joined[0] == '/') {
            logical = try canonical(sh, joined);
            target = logical.?;
        }
    }
    var buf: [4096]u8 = undefined;
    var z = sys.cstr(&buf, target) orelse {
        sh.bmsg(who, "{s}: File name too long", .{dir});
        return false;
    };
    if (sys.chdir(z) != 0) {
        if (logical != null) {
            z = sys.cstr(&buf, dir) orelse return false;
            if (sys.chdir(z) == 0) {
                logical = null;
            } else {
                sh.bmsg(who, "{s}: {s}", .{ dir, sys.msg_for(sys.errno()) });
                return false;
            }
        } else {
            sh.bmsg(who, "{s}: {s}", .{ dir, sys.msg_for(sys.errno()) });
            return false;
        }
    }
    const old = sh.get_scalar("PWD");
    if (old) |o| try sh.assign_scalar("OLDPWD", o, false) else {
        if (sh.find("OLDPWD") == null) try sh.assign_scalar("OLDPWD", "", false);
    }
    const newpwd: []const u8 = if (logical != null and !physical) logical.? else (physical_cwd(sh) orelse dir);
    try sh.assign_scalar("PWD", newpwd, false);
    try sh.set_cwd_logical(newpwd);
    if (print_new) _ = sh.out(try std.mem.concat(sh.sa, u8, &.{ newpwd, "\n" }));
    return true;
}

fn bi_cd(sh: *Shell, argv: []const []const u8) Err!u8 {
    var physical = sh.opt(.physical);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        var okf = true;
        for (a[1..]) |c| {
            switch (c) {
                'L' => physical = false,
                'P' => physical = true,
                'e', '@' => {},
                else => {
                    sh.bmsg("cd", "-{c}: invalid option", .{c});
                    sh.usage_msg("cd", "cd [-L|[-P [-e]] [-@]] [dir]");
                    return 2;
                },
            }
            if (!okf) break;
        }
        okf = true;
    }
    const args = argv[i..];
    if (args.len > 1) {
        sh.bmsg("cd", "too many arguments", .{});
        return 1;
    }
    var print_new = false;
    var dir: []const u8 = undefined;
    if (args.len == 0) {
        dir = sh.get_scalar("HOME") orelse {
            sh.bmsg("cd", "HOME not set", .{});
            return 1;
        };
        if (dir.len == 0) return 0;
    } else if (std.mem.eql(u8, args[0], "-")) {
        dir = sh.get_scalar("OLDPWD") orelse {
            sh.bmsg("cd", "OLDPWD not set", .{});
            return 1;
        };
        print_new = true;
    } else dir = args[0];
    if (dir.len == 0) return 0;
    if (!(dir[0] == '/') and !std.mem.startsWith(u8, dir, "./") and !std.mem.startsWith(u8, dir, "../") and !std.mem.eql(u8, dir, ".") and !std.mem.eql(u8, dir, "..")) {
        if (sh.get_scalar("CDPATH")) |cp| {
            var it = std.mem.splitScalar(u8, cp, ':');
            while (it.next()) |c| {
                const base = if (c.len == 0) "." else c;
                const cand = try std.mem.concat(sh.sa, u8, &.{ base, "/", dir });
                if (sys.stat_path(cand, true)) |st| {
                    if (st.is_dir()) {
                        const show = c.len > 0 and !std.mem.eql(u8, c, ".");
                        const ok = try do_chdir(sh, "cd", cand, physical, show);
                        return if (ok) 0 else 1;
                    }
                }
            }
        }
    }
    const ok = try do_chdir(sh, "cd", dir, physical, print_new);
    return if (ok) 0 else 1;
}

fn parse_status_arg(sh: *Shell, name: []const u8, s: []const u8) ?i64 {
    const t = std.mem.trim(u8, s, " \t");
    const v = std.fmt.parseInt(i64, t, 10) catch {
        sh.bmsg(name, "{s}: numeric argument required", .{s});
        return null;
    };
    return v;
}

fn bi_exit(sh: *Shell, argv: []const []const u8) Err!u8 {
    var code: u8 = sh.trap_entry_status orelse sh.status;
    if (argv.len > 1) {
        if (parse_status_arg(sh, "exit", argv[1])) |v| {
            if (argv.len > 2) {
                sh.bmsg("exit", "too many arguments", .{});
                return 1;
            }
            code = @truncate(@as(u64, @bitCast(v)));
        } else {
            code = 2;
        }
    }
    sh.status = code;
    sh.exit_status_pending = code;
    return error.Exit;
}

fn bi_return(sh: *Shell, argv: []const []const u8) Err!u8 {
    var code: u8 = sh.status;
    if (argv.len > 1) {
        if (parse_status_arg(sh, "return", argv[1])) |v| {
            code = @truncate(@as(u64, @bitCast(v)));
        } else {
            sh.status = 2;
            return 2;
        }
    }
    if (sh.frames.items.len == 0 and sh.in_source_depth == 0) {
        sh.bmsg("return", "can only `return' from a function or sourced script", .{});
        return 2;
    }
    sh.status = code;
    return error.Return;
}

fn loop_ctl(sh: *Shell, argv: []const []const u8, is_break: bool) Err!u8 {
    const name = argv[0];
    var n: i64 = 1;
    if (argv.len > 1) {
        n = std.fmt.parseInt(i64, std.mem.trim(u8, argv[1], " "), 10) catch {
            sh.bmsg(name, "{s}: numeric argument required", .{argv[1]});
            return 1;
        };
        if (n <= 0) {
            sh.bmsg(name, "{s}: loop count out of range", .{argv[1]});
            return 1;
        }
    }
    if (sh.loop_depth == 0) {
        sh.bmsg(name, "only meaningful in a `for', `while', or `until' loop", .{});
        return 0;
    }
    sh.status = 0;
    sh.ctl_n = @intCast(@min(n, @as(i64, sh.loop_depth)));
    return if (is_break) error.Break else error.Continue;
}

fn bi_break(sh: *Shell, argv: []const []const u8) Err!u8 {
    return loop_ctl(sh, argv, true);
}
fn bi_continue(sh: *Shell, argv: []const []const u8) Err!u8 {
    return loop_ctl(sh, argv, false);
}

fn bi_shift(sh: *Shell, argv: []const []const u8) Err!u8 {
    var n: i64 = 1;
    if (argv.len > 1) {
        n = std.fmt.parseInt(i64, std.mem.trim(u8, argv[1], " "), 10) catch {
            sh.bmsg("shift", "{s}: numeric argument required", .{argv[1]});
            return 1;
        };
    }
    if (argv.len > 2) {
        sh.bmsg("shift", "too many arguments", .{});
        return 1;
    }
    if (n < 0) {
        sh.bmsg("shift", "{d}: shift count out of range", .{n});
        return 1;
    }
    const un: usize = @intCast(n);
    if (un > sh.pos.items.len) {
        if (sh.shopt(.shift_verbose)) sh.bmsg("shift", "{d}: shift count out of range", .{n});
        return 1;
    }
    for (sh.pos.items[0..un]) |p| sh.gpa.free(p);
    const rest = sh.pos.items.len - un;
    std.mem.copyForwards([]u8, sh.pos.items[0..rest], sh.pos.items[un..]);
    sh.pos.items.len = rest;
    return 0;
}

const short_opts = [_]struct { c: u8, o: shell.Opt }{
    .{ .c = 'a', .o = .allexport },
    .{ .c = 'b', .o = .notify },
    .{ .c = 'e', .o = .errexit },
    .{ .c = 'f', .o = .noglob },
    .{ .c = 'h', .o = .hashall },
    .{ .c = 'k', .o = .keyword },
    .{ .c = 'm', .o = .monitor },
    .{ .c = 'n', .o = .noexec },
    .{ .c = 'p', .o = .privileged },
    .{ .c = 't', .o = .onecmd },
    .{ .c = 'u', .o = .nounset },
    .{ .c = 'v', .o = .verbose },
    .{ .c = 'x', .o = .xtrace },
    .{ .c = 'B', .o = .braceexpand },
    .{ .c = 'C', .o = .noclobber },
    .{ .c = 'E', .o = .errtrace },
    .{ .c = 'H', .o = .histexpand },
    .{ .c = 'P', .o = .physical },
    .{ .c = 'T', .o = .functrace },
};

fn opt_by_name(name: []const u8) ?shell.Opt {
    for (shell.opt_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @enumFromInt(i);
    }
    return null;
}

fn bi_set(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (argv.len == 1) {
        var out: std.ArrayList(u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        var it = sh.vars.map.iterator();
        while (it.next()) |e| try names.append(sh.sa, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, lessStr);
        for (names.items) |n| {
            const v = sh.vars.get(n).?;
            if (v.value == .none and v.special == .none) continue;
            try bi_decl.print_set_style(sh, v, &out);
        }
        _ = sh.out(out.items);
        try bi_decl.list_functions(sh, false, false);
        return 0;
    }
    var i: usize = 1;
    while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            try sh.set_pos(argv[i..]);
            return 0;
        }
        if (std.mem.eql(u8, a, "-")) {
            sh.set_opt(.xtrace, false);
            sh.set_opt(.verbose, false);
            i += 1;
            if (i < argv.len) try sh.set_pos(argv[i..]);
            return 0;
        }
        if (a.len < 2 or (a[0] != '-' and a[0] != '+')) break;
        const on = a[0] == '-';
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            if (c == 'o') {
                if (i + 1 < argv.len and !(argv[i + 1].len > 0 and (argv[i + 1][0] == '-' or argv[i + 1][0] == '+'))) {
                    const nm = argv[i + 1];
                    const o = opt_by_name(nm) orelse {
                        sh.bmsg("set", "{s}: invalid option name", .{nm});
                        return 2;
                    };
                    sh.set_opt(o, on);
                    i += 1;
                } else {
                    var out: std.ArrayList(u8) = .empty;
                    for (shell.opt_names, 0..) |n, k| {
                        if (on) {
                            try out.print(sh.sa, "{s: <15}\t{s}\n", .{ n, if (sh.opts[k]) "on" else "off" });
                        } else try out.print(sh.sa, "set {s}o {s}\n", .{ if (sh.opts[k]) "-" else "+", n });
                    }
                    _ = sh.out(out.items);
                }
                continue;
            }
            var found = false;
            for (short_opts) |so| {
                if (so.c == c) {
                    sh.set_opt(so.o, on);
                    found = true;
                    break;
                }
            }
            if (!found) {
                sh.bmsg("set", "{c}{c}: invalid option", .{ a[0], c });
                sh.usage_msg("set", "set [-abefhkmnptuvxBCHP] [-o option-name] [--] [-] [arg ...]");
                return 2;
            }
        }
        i += 1;
    }
    if (i < argv.len) try sh.set_pos(argv[i..]);
    return 0;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn bi_shopt(sh: *Shell, argv: []const []const u8) Err!u8 {
    var set: ?bool = null;
    var quiet = false;
    var print = false;
    var o_mode = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                's' => set = true,
                'u' => set = false,
                'q' => quiet = true,
                'p' => print = true,
                'o' => o_mode = true,
                else => {
                    sh.bmsg("shopt", "-{c}: invalid option", .{c});
                    sh.usage_msg("shopt", "shopt [-pqsu] [-o] [optname ...]");
                    return 2;
                },
            }
        }
    }
    const names = argv[i..];
    const shopt_names = comptime blk: {
        const fields = @typeInfo(shell.Shopt).@"enum".fields;
        var arr: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, k| arr[k] = f.name;
        break :blk arr;
    };
    var out: std.ArrayList(u8) = .empty;
    var status: u8 = 0;
    if (names.len == 0) {
        if (o_mode) {
            for (shell.opt_names, 0..) |n, k| {
                if (set != null and sh.opts[k] != set.?) continue;
                if (print) {
                    try out.print(sh.sa, "set {s}o {s}\n", .{ if (sh.opts[k]) "-" else "+", n });
                } else try out.print(sh.sa, "{s: <15}\t{s}\n", .{ n, if (sh.opts[k]) "on" else "off" });
            }
        } else {
            for (shopt_names, 0..) |n, k| {
                if (set != null and sh.shopts[k] != set.?) continue;
                if (set != null and false) continue;
                if (print) {
                    try out.print(sh.sa, "shopt {s} {s}\n", .{ if (sh.shopts[k]) "-s" else "-u", n });
                } else try out.print(sh.sa, "{s: <15}\t{s}\n", .{ n, if (sh.shopts[k]) "on" else "off" });
            }
        }
        if (!quiet) _ = sh.out(out.items);
        return 0;
    }
    for (names) |n| {
        if (o_mode) {
            const o = opt_by_name(n) orelse {
                sh.bmsg("shopt", "{s}: invalid shell option name", .{n});
                status = 1;
                continue;
            };
            if (set) |s| {
                sh.set_opt(o, s);
            } else {
                const cur = sh.opt(o);
                if (!cur) status = 1;
                if (print) {
                    try out.print(sh.sa, "set {s}o {s}\n", .{ if (cur) "-" else "+", n });
                } else try out.print(sh.sa, "{s: <15}\t{s}\n", .{ n, if (cur) "on" else "off" });
            }
            continue;
        }
        var idx: ?usize = null;
        for (shopt_names, 0..) |sn, k| if (std.mem.eql(u8, sn, n)) {
            idx = k;
        };
        const k = idx orelse {
            sh.bmsg("shopt", "{s}: invalid shell option name", .{n});
            status = 1;
            continue;
        };
        if (set) |s| {
            sh.shopts[k] = s;
        } else {
            if (!sh.shopts[k]) status = 1;
            if (print) {
                try out.print(sh.sa, "shopt {s} {s}\n", .{ if (sh.shopts[k]) "-s" else "-u", n });
            } else try out.print(sh.sa, "{s: <15}\t{s}\n", .{ n, if (sh.shopts[k]) "on" else "off" });
        }
    }
    if (!quiet) _ = sh.out(out.items);
    return status;
}

fn bi_unset(sh: *Shell, argv: []const []const u8) Err!u8 {
    var mode_f = false;
    var mode_n = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                'f' => mode_f = true,
                'v' => mode_f = false,
                'n' => mode_n = true,
                else => {
                    sh.bmsg("unset", "-{c}: invalid option", .{c});
                    sh.usage_msg("unset", "unset [-f] [-v] [-n] [name ...]");
                    return 2;
                },
            }
        }
    }
    var status: u8 = 0;
    for (argv[i..]) |n| {
        if (mode_f) {
            if (sh.funcs.fetchRemove(n)) |kv| {
                sh.gpa.free(kv.key);
                sh.gpa.destroy(kv.value);
                sh.func_gen +%= 1;
            }
            continue;
        }
        if (std.mem.findScalar(u8, n, '[')) |lb| {
            if (n[n.len - 1] == ']' and Shell.is_valid_name(n[0..lb])) {
                const name = n[0..lb];
                const sub = n[lb + 1 .. n.len - 1];
                const v = sh.find(name) orelse continue;
                if (v.flags.readonly) {
                    sh.bmsg("unset", "{s}: cannot unset: readonly variable", .{name});
                    status = 1;
                    continue;
                }
                if (std.mem.eql(u8, sub, "@") or std.mem.eql(u8, sub, "*")) {
                    sh.clear_array(v);
                    continue;
                }
                switch (v.value) {
                    .assoc => |*m| _ = m.remove(sh.gpa, sub),
                    .indexed => |*ix| {
                        var idx = try sh.eval_int(sub);
                        if (idx < 0) idx += ix.max_index() + 1;
                        _ = ix.remove(sh.gpa, idx);
                    },
                    .str => {
                        const idx = try sh.eval_int(sub);
                        if (idx == 0) _ = try sh.unset_var(name);
                    },
                    .none => {},
                }
                continue;
            }
        }
        if (!Shell.is_valid_name(n)) continue;
        if (mode_n) {
            if (sh.vars.get(n)) |v| {
                if (v.flags.nameref) {
                    _ = try sh.unset_var_raw(n);
                    continue;
                }
            }
        }
        if (!try sh.unset_var(n)) status = 1;
    }
    return status;
}

fn bi_eval(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len) return 0;
    const text = try join_args(sh, argv[i..]);
    if (std.mem.trim(u8, text, " \t\n").len == 0) return 0;
    sh.eval_depth += 1;
    defer sh.eval_depth -= 1;
    var line = sh.lineno;
    if (sh.cur_cmd) |cc| {
        if (cc.end_line > line) line = cc.end_line;
    }
    const st = try exec.run_string(sh, text, .{ .label = "eval", .line_base = if (line > 0) line - 1 else 0 });
    sh.lineno = line;
    return st;
}

fn join_args(sh: *Shell, args: []const []const u8) Err![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, k| {
        if (k > 0) try out.append(sh.sa, ' ');
        try out.appendSlice(sh.sa, a);
    }
    return out.items;
}

fn bi_source(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len) {
        sh.bmsg(argv[0], "filename argument required", .{});
        sh.usage_msg(argv[0], ".  filename [arguments]");
        return 2;
    }
    const name = argv[i];
    var path: []const u8 = name;
    var found = false;
    if (std.mem.findScalar(u8, name, '/') == null and sh.shopt(.sourcepath)) {
        const pv = exec.path_value(sh);
        var it = std.mem.splitScalar(u8, pv, ':');
        while (it.next()) |d| {
            const dd = if (d.len == 0) "." else d;
            const cand = try std.mem.concat(sh.sa, u8, &.{ dd, "/", name });
            if (sys.stat_path(cand, true)) |st| {
                if (st.is_reg()) {
                    path = cand;
                    found = true;
                    break;
                }
            }
        }
    }
    if (!found) {
        if (sys.stat_path(name, true)) |st| {
            if (st.is_dir()) {
                sh.bmsg(argv[0], "{s}: is a directory", .{name});
                return 1;
            }
        }
    }
    const content = exec.read_whole_file(sh, path) orelse {
        sh.msg("{s}: {s}", .{ name, if (sys.errno() == sys.ENOENT or sys.errno() == 0) "No such file or directory" else sys.msg_for(sys.errno()) });
        return 1;
    };
    const saved_pos = sh.pos;
    var replaced = false;
    if (i + 1 < argv.len) {
        sh.pos = .empty;
        try sh.set_pos(argv[i + 1 ..]);
        replaced = true;
    }
    const saved_file = sh.cur_file;
    const saved_line = sh.lineno;
    const src_func = try sh.gpa.create(shell.Func);
    src_func.* = .{ .name = "source", .body = undefined, .file = try sh.gpa.dupe(u8, name), .line = 0 };
    sh.cur_file = src_func.file;
    try sh.frames.append(sh.gpa, .{ .func = src_func, .call_line = saved_line, .call_file = saved_file, .saved_pos = .empty, .saved_file = saved_file, .is_source = true });
    sh.in_source_depth += 1;
    const status = exec.run_source_text(sh, content, name, 0) catch |e| blk: {
        switch (e) {
            error.Return => break :blk sh.status,
            else => {
                var fr = sh.frames.pop().?;
                sh.pop_locals(&fr);
                sh.in_source_depth -= 1;
                sh.cur_file = saved_file;
                sh.lineno = saved_line;
                if (replaced) {
                    for (sh.pos.items) |p| sh.gpa.free(p);
                    sh.pos.deinit(sh.gpa);
                    sh.pos = saved_pos;
                }
                return e;
            },
        }
    };
    var fr = sh.frames.pop().?;
    sh.pop_locals(&fr);
    sh.in_source_depth -= 1;
    sh.cur_file = saved_file;
    sh.lineno = saved_line;
    if (replaced) {
        for (sh.pos.items) |p| sh.gpa.free(p);
        sh.pos.deinit(sh.gpa);
        sh.pos = saved_pos;
    }
    return status;
}

fn bi_exec(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var clear_env = false;
    var login = false;
    var argv0: ?[]const u8 = null;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-c")) {
            clear_env = true;
        } else if (std.mem.eql(u8, a, "-l")) {
            login = true;
        } else if (std.mem.eql(u8, a, "-a")) {
            i += 1;
            if (i < argv.len) argv0 = argv[i];
        } else {
            sh.bmsg("exec", "-{c}: invalid option", .{a[1]});
            sh.usage_msg("exec", "exec [-cl] [-a name] [command [argument ...]] [redirection ...]");
            return 2;
        }
    }
    if (i >= argv.len) return 0;
    const name = argv[i];
    var args = try sh.sa.dupe([]const u8, argv[i..]);
    if (argv0) |z| args[0] = z;
    const r = try exec.resolve(sh, name, false);
    switch (r) {
        .found => |p| {
            for (sh.procsub_fds.items) |fd| _ = sys.close(fd);
            var pbuf: [4096]u8 = undefined;
            const pz = sys.cstr(&pbuf, p) orelse return 126;
            const argz = try make_argv_z(sh, args);
            exec.child_prepare_exec(sh);
            if (sh.trap_exit.kind == .cmd) {
                sh.trap_exit = .{};
            }
            if (sh.vars.get("SHLVL")) |sv| {
                if (sv.flags.exported and sv.value == .str) {
                    const lvl = std.fmt.parseInt(i64, sv.value.str, 10) catch 1;
                    const nv = try sh.tmp_fmt("{d}", .{@max(lvl - 1, 0)});
                    try sh.assign_scalar("SHLVL", nv, false);
                }
            }
            if (clear_env) {
                const empty = [_]?[*:0]const u8{null};
                _ = sys.execve(pz, argz, @ptrCast(&empty));
            } else {
                const env = try sh.env_block_get();
                _ = sys.execve(pz, argz, @ptrCast(env.ptrs.items.ptr));
            }
            const st = exec.exec_failed(sh, p, args);
            if (!sh.shopt(.execfail) and !sh.interactive) {
                sh.exit_status_pending = st;
                sh.status = st;
                return error.Exit;
            }
            return st;
        },
        .not_found => {
            if (std.mem.findScalar(u8, name, '/') != null) {
                sh.msg("{s}: No such file or directory", .{name});
            } else sh.bmsg("exec", "{s}: not found", .{name});
            if (!sh.shopt(.execfail) and !sh.interactive) {
                sh.exit_status_pending = 127;
                sh.status = 127;
                return error.Exit;
            }
            return 127;
        },
        .denied => |p| {
            sh.msg("{s}: Permission denied", .{p});
            if (!sh.shopt(.execfail) and !sh.interactive) {
                sh.exit_status_pending = 126;
                sh.status = 126;
                return error.Exit;
            }
            return 126;
        },
        .is_dir => |p| {
            sh.msg("{s}: Is a directory", .{p});
            if (!sh.shopt(.execfail) and !sh.interactive) {
                sh.exit_status_pending = 126;
                sh.status = 126;
                return error.Exit;
            }
            return 126;
        },
    }
}

fn make_argv_z(sh: *Shell, argv: []const []const u8) Err![*:null]const ?[*:0]const u8 {
    const a = sh.sa;
    const arr = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| {
        const z = try a.allocSentinel(u8, s.len, 0);
        @memcpy(z[0..s.len], s);
        arr[i] = z.ptr;
    }
    arr[argv.len] = null;
    return @ptrCast(arr.ptr);
}

const keywords = [_][]const u8{ "!", "[[", "]]", "{", "}", "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "time", "until", "while" };

fn is_keyword(n: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, n)) return true;
    return false;
}

fn bi_command(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var mode_v = false;
    var mode_vv = false;
    var use_default_path = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                'v' => mode_v = true,
                'V' => mode_vv = true,
                'p' => use_default_path = true,
                else => {
                    sh.bmsg("command", "-{c}: invalid option", .{c});
                    sh.usage_msg("command", "command [-pVv] command [arg ...]");
                    return 2;
                },
            }
        }
    }
    if (i >= argv.len) return 0;
    var saved_path: ?[]u8 = null;
    if (use_default_path) {
        if (sh.get_scalar("PATH")) |p| saved_path = try sh.gpa.dupe(u8, p);
        try sh.assign_scalar("PATH", "/bin:/usr/bin", false);
    }
    defer if (use_default_path) {
        if (saved_path) |p| {
            sh.assign_scalar("PATH", p, false) catch {};
            sh.gpa.free(p);
        } else _ = sh.unset_var("PATH") catch false;
    };
    if (mode_v or mode_vv) {
        var status: u8 = 0;
        for (argv[i..]) |n| {
            if (!try describe(sh, n, if (mode_vv) .verbose else .brief, false, use_default_path)) {
                if (mode_vv) sh.bmsg("command", "{s}: not found", .{n});
                status = 1;
            }
        }
        return status;
    }
    return exec.dispatch_ex(sh, argv[i..], &.{}, false, &.{}, false, .{ .skip_funcs = true });
}

fn bi_builtin(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--")) i += 1;
    if (i >= argv.len) return 0;
    if (lookup(argv[i]) == null) {
        sh.bmsg("builtin", "{s}: not a shell builtin", .{argv[i]});
        return 1;
    }
    return exec.dispatch_ex(sh, argv[i..], &.{}, false, &.{}, false, .{ .builtin_only = true });
}

const DescMode = enum { brief, verbose, type_t };

fn describe(sh: *Shell, name: []const u8, mode: DescMode, all: bool, default_path: bool) Err!bool {
    _ = default_path;
    var found = false;
    var out: std.ArrayList(u8) = .empty;
    const a = sh.sa;
    if (sh.aliases.get(name)) |al| {
        found = true;
        switch (mode) {
            .brief => try out.print(a, "alias {s}='{s}'\n", .{ name, al }),
            .verbose => try out.print(a, "{s} is aliased to `{s}'\n", .{ name, al }),
            .type_t => try out.appendSlice(a, "alias\n"),
        }
        if (!all) {
            _ = sh.out(out.items);
            return true;
        }
    }
    if (is_keyword(name)) {
        found = true;
        switch (mode) {
            .brief => try out.print(a, "{s}\n", .{name}),
            .verbose => try out.print(a, "{s} is a shell keyword\n", .{name}),
            .type_t => try out.appendSlice(a, "keyword\n"),
        }
        if (!all) {
            _ = sh.out(out.items);
            return true;
        }
    }
    if (sh.funcs.get(name)) |f| {
        found = true;
        switch (mode) {
            .brief => try out.print(a, "{s}\n", .{name}),
            .verbose => {
                try out.print(a, "{s} is a function\n", .{name});
                try unparse.function_text(sh, name, f.body, &out);
            },
            .type_t => try out.appendSlice(a, "function\n"),
        }
        if (!all) {
            _ = sh.out(out.items);
            return true;
        }
    }
    if (is_builtin(name)) {
        found = true;
        switch (mode) {
            .brief => try out.print(a, "{s}\n", .{name}),
            .verbose => try out.print(a, "{s} is a shell builtin\n", .{name}),
            .type_t => try out.appendSlice(a, "builtin\n"),
        }
        if (!all) {
            _ = sh.out(out.items);
            return true;
        }
    }
    if (all) {
        const pv = exec.path_value(sh);
        var it = std.mem.splitScalar(u8, pv, ':');
        while (it.next()) |d| {
            const dd = if (d.len == 0) "." else d;
            const cand = try std.mem.concat(sh.sa, u8, &.{ dd, "/", name });
            if (sys.stat_path(cand, true)) |st| {
                if (st.is_reg() and sys.path_exec_ok(cand)) {
                    found = true;
                    switch (mode) {
                        .brief => try out.print(a, "{s}\n", .{cand}),
                        .verbose => try out.print(a, "{s} is {s}\n", .{ name, cand }),
                        .type_t => try out.appendSlice(a, "file\n"),
                    }
                }
            }
        }
    } else {
        const r = try exec.resolve(sh, name, false);
        switch (r) {
            .found => |p| {
                found = true;
                const hashed = sh.cmd_hash.contains(name);
                switch (mode) {
                    .brief => try out.print(a, "{s}\n", .{p}),
                    .verbose => {
                        if (hashed) try out.print(a, "{s} is hashed ({s})\n", .{ name, p }) else try out.print(a, "{s} is {s}\n", .{ name, p });
                    },
                    .type_t => try out.appendSlice(a, "file\n"),
                }
            },
            else => {},
        }
    }
    if (out.items.len > 0) _ = sh.out(out.items);
    return found;
}

fn bi_type(sh: *Shell, argv: []const []const u8) Err!u8 {
    var mode: DescMode = .verbose;
    var all = false;
    var path_only = false;
    var force_path = false;
    var no_func = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-type")) {
            mode = .type_t;
            continue;
        }
        if (std.mem.eql(u8, a, "-path")) {
            path_only = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-all")) {
            all = true;
            continue;
        }
        for (a[1..]) |c| {
            switch (c) {
                't' => mode = .type_t,
                'a' => all = true,
                'p' => path_only = true,
                'P' => {
                    path_only = true;
                    force_path = true;
                },
                'f' => no_func = true,
                else => {
                    sh.bmsg("type", "-{c}: invalid option", .{c});
                    sh.usage_msg("type", "type [-afptP] name [name ...]");
                    return 2;
                },
            }
        }
    }
    var status: u8 = 0;
    for (argv[i..]) |n| {
        if (path_only) {
            const is_special = !force_path and (sh.funcs.contains(n) or is_builtin(n) or is_keyword(n) or sh.aliases.contains(n));
            if (is_special and mode == .type_t) {
                status = 1;
                continue;
            }
            if (is_special) {
                status = 1;
                continue;
            }
            const r = try exec.resolve(sh, n, false);
            switch (r) {
                .found => |p| {
                    if (mode == .type_t) _ = sh.out("file\n") else _ = sh.out(try std.mem.concat(sh.sa, u8, &.{ p, "\n" }));
                },
                else => status = 1,
            }
            continue;
        }
        if (!try describe(sh, n, mode, all, false)) {
            if (mode != .type_t) sh.bmsg("type", "{s}: not found", .{n});
            status = 1;
        }
    }
    return status;
}

fn bi_hash(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var delete = false;
    var list = false;
    var path_arg: ?[]const u8 = null;
    var tmode = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..], 1..) |c, k| {
            switch (c) {
                'r' => {
                    exec.flush_hash(sh);
                },
                'd' => delete = true,
                'l' => list = true,
                't' => tmode = true,
                'p' => {
                    if (k + 1 < a.len) {
                        path_arg = a[k + 1 ..];
                    } else {
                        i += 1;
                        if (i >= argv.len) {
                            sh.bmsg("hash", "-p: option requires an argument", .{});
                            return 2;
                        }
                        path_arg = argv[i];
                    }
                    break;
                },
                else => {
                    sh.bmsg("hash", "-{c}: invalid option", .{c});
                    sh.usage_msg("hash", "hash [-lr] [-p pathname] [-dt] [name ...]");
                    return 2;
                },
            }
        }
    }
    const names = argv[i..];
    if (names.len == 0) {
        if (argv.len > 1 and !list and !delete and !tmode and path_arg == null) {
            return 0;
        }
        if (sh.cmd_hash.count() == 0) {
            if (!list) _ = sh.out("hash: hash table empty\n");
            return 0;
        }
        var out: std.ArrayList(u8) = .empty;
        if (!list) try out.appendSlice(sh.sa, "hits\tcommand\n");
        var it = sh.cmd_hash.iterator();
        while (it.next()) |e| {
            if (list) {
                try out.print(sh.sa, "builtin hash -p {s} {s}\n", .{ e.value_ptr.path, e.key_ptr.* });
            } else try out.print(sh.sa, "{d: >4}\t{s}\n", .{ e.value_ptr.hits, e.value_ptr.path });
        }
        _ = sh.out(out.items);
        return 0;
    }
    var status: u8 = 0;
    for (names) |n| {
        if (delete) {
            if (sh.cmd_hash.fetchRemove(n)) |kv| {
                sh.gpa.free(kv.key);
                sh.gpa.free(kv.value.path);
            } else {
                sh.bmsg("hash", "{s}: not found", .{n});
                status = 1;
            }
            continue;
        }
        if (tmode) {
            if (sh.cmd_hash.get(n)) |e| {
                _ = sh.out(try std.mem.concat(sh.sa, u8, &.{ e.path, "\n" }));
            } else {
                sh.bmsg("hash", "{s}: not found", .{n});
                status = 1;
            }
            continue;
        }
        if (path_arg) |p| {
            const k = try sh.gpa.dupe(u8, n);
            const v = try sh.gpa.dupe(u8, p);
            if (try sh.cmd_hash.fetchPut(sh.gpa, k, .{ .path = v })) |old| {
                sh.gpa.free(old.key);
                sh.gpa.free(old.value.path);
            }
            continue;
        }
        if (is_builtin(n)) continue;
        const r = try exec.resolve(sh, n, true);
        switch (r) {
            .found => {},
            else => {
                sh.bmsg("hash", "{s}: not found", .{n});
                status = 1;
            },
        }
    }
    return status;
}

fn bi_alias(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var print = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-p")) print = true else {
            sh.bmsg("alias", "{s}: invalid option", .{a});
            sh.usage_msg("alias", "alias [-p] [name[=value] ... ]");
            return 2;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    if (i >= argv.len) {
        var names: std.ArrayList([]const u8) = .empty;
        var it = sh.aliases.iterator();
        while (it.next()) |e| try names.append(sh.sa, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, lessStr);
        for (names.items) |n| {
            try out.print(sh.sa, "alias {s}=", .{n});
            try strutil.single_quote(sh.sa, &out, sh.aliases.get(n).?);
            try out.append(sh.sa, '\n');
        }
        _ = sh.out(out.items);
        return 0;
    }
    var status: u8 = 0;
    for (argv[i..]) |arg| {
        if (std.mem.findScalar(u8, arg, '=')) |eq| {
            const n = arg[0..eq];
            const v = arg[eq + 1 ..];
            if (n.len == 0 or std.mem.findAny(u8, n, " \t\n/$`\"'\\|&;()<>") != null) {
                sh.bmsg("alias", "`{s}': invalid alias name", .{n});
                status = 1;
                continue;
            }
            const k = try sh.gpa.dupe(u8, n);
            const vv = try sh.gpa.dupe(u8, v);
            if (try sh.aliases.fetchPut(sh.gpa, k, vv)) |old| {
                sh.gpa.free(old.key);
                sh.gpa.free(old.value);
            }
            sh.alias_gen +%= 1;
            const lk = try sh.gpa.dupe(u8, n);
            if (try sh.alias_lines.fetchPut(sh.gpa, lk, sh.lineno)) |old| sh.gpa.free(old.key);
        } else {
            if (sh.aliases.get(arg)) |v| {
                try out.print(sh.sa, "alias {s}=", .{arg});
                try strutil.single_quote(sh.sa, &out, v);
                try out.append(sh.sa, '\n');
            } else {
                sh.bmsg("alias", "{s}: not found", .{arg});
                status = 1;
            }
        }
    }
    _ = sh.out(out.items);
    return status;
}

fn bi_unalias(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var all = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-a")) all = true else {
            sh.bmsg("unalias", "{s}: invalid option", .{a});
            sh.usage_msg("unalias", "unalias [-a] name [name ...]");
            return 2;
        }
    }
    if (all) {
        var it = sh.aliases.iterator();
        while (it.next()) |e| {
            sh.gpa.free(e.key_ptr.*);
            sh.gpa.free(e.value_ptr.*);
        }
        sh.aliases.clearRetainingCapacity();
        sh.alias_lines.clearRetainingCapacity();
        sh.alias_gen +%= 1;
        return 0;
    }
    if (i >= argv.len) {
        sh.usage_msg("unalias", "unalias [-a] name [name ...]");
        return 2;
    }
    var status: u8 = 0;
    for (argv[i..]) |n| {
        if (sh.aliases.fetchRemove(n)) |kv| {
            if (sh.alias_lines.fetchRemove(n)) |lk| sh.gpa.free(lk.key);
            sh.gpa.free(kv.key);
            sh.gpa.free(kv.value);
            sh.alias_gen +%= 1;
        } else {
            sh.bmsg("unalias", "{s}: not found", .{n});
            status = 1;
        }
    }
    return status;
}

fn trap_slot(sh: *Shell, sig: u32) *shell.Trap {
    return &sh.traps[sig];
}

fn set_trap(sh: *Shell, spec: []const u8, action: ?[]const u8) Err!bool {
    const up = blk: {
        var b: [16]u8 = undefined;
        if (spec.len > b.len) break :blk spec;
        for (spec, 0..) |c, k| b[k] = std.ascii.toUpper(c);
        break :blk try sh.sa.dupe(u8, b[0..spec.len]);
    };
    var stripped = up;
    if (std.mem.startsWith(u8, stripped, "SIG")) stripped = stripped[3..];
    var tr: ?*shell.Trap = null;
    var sig_num: u32 = 0;
    if (std.mem.eql(u8, stripped, "ERR")) {
        tr = &sh.trap_err;
    } else if (std.mem.eql(u8, stripped, "DEBUG")) {
        tr = &sh.trap_debug;
    } else if (std.mem.eql(u8, stripped, "RETURN")) {
        tr = &sh.trap_return;
    } else if (std.mem.eql(u8, stripped, "EXIT") or std.mem.eql(u8, spec, "0")) {
        tr = &sh.trap_exit;
    } else {
        sig_num = signals.parse(spec) orelse {
            sh.bmsg("trap", "{s}: invalid signal specification", .{spec});
            return false;
        };
        tr = &sh.traps[sig_num];
    }
    const t = tr.?;
    if (t.kind == .cmd) sh.gpa.free(t.cmd);
    if (action == null) {
        t.* = .{};
        if (sig_num > 0) sys.set_signal(@intCast(sig_num), sys.SIG_DFL);
    } else if (action.?.len == 0) {
        t.* = .{ .kind = .ignore };
        if (sig_num > 0) sys.set_signal(@intCast(sig_num), sys.SIG_IGN);
    } else {
        t.* = .{ .kind = .cmd, .cmd = try sh.gpa.dupe(u8, action.?) };
        if (sig_num > 0 and sig_num != 9 and sig_num != 19) {
            var act: sys.SigAction = .{ .handler = @intFromPtr(&shell.signal_handler) };
            _ = sys.sigemptyset(&act.mask);
            _ = sys.sigaction(@intCast(sig_num), &act, null);
        }
    }
    return true;
}

fn print_traps(sh: *Shell) Err!void {
    var out: std.ArrayList(u8) = .empty;
    const a = sh.sa;
    const pseudo = [_]struct { n: []const u8, t: shell.Trap }{
        .{ .n = "EXIT", .t = sh.trap_exit },
        .{ .n = "DEBUG", .t = sh.trap_debug },
        .{ .n = "RETURN", .t = sh.trap_return },
        .{ .n = "ERR", .t = sh.trap_err },
    };
    for (pseudo[0..1]) |p| try print_one_trap(sh, &out, p.n, p.t);
    var i: usize = 1;
    while (i < shell.nsig) : (i += 1) {
        var nb: [16]u8 = undefined;
        const nm = try std.fmt.allocPrint(a, "SIG{s}", .{signals.name_of(@intCast(i), &nb)});
        try print_one_trap(sh, &out, nm, sh.traps[i]);
    }
    for (pseudo[1..]) |p| try print_one_trap(sh, &out, p.n, p.t);
    _ = sh.out(out.items);
}

fn print_one_trap(sh: *Shell, out: *std.ArrayList(u8), name: []const u8, t: shell.Trap) Err!void {
    const a = sh.sa;
    switch (t.kind) {
        .none => {},
        .ignore => try out.print(a, "trap -- '' {s}\n", .{name}),
        .cmd => {
            try out.appendSlice(a, "trap -- ");
            try strutil.single_quote(a, out, t.cmd);
            try out.print(a, " {s}\n", .{name});
        },
    }
}

fn print_signal_list(sh: *Shell, names_only: bool) Err!void {
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    var i: u32 = 1;
    while (i <= 64) : (i += 1) {
        if (i >= 32 and i < 34) continue;
        var nb: [16]u8 = undefined;
        const nm = signals.name_of(i, &nb);
        if (names_only) {
            try out.print(sh.sa, "{s}\n", .{nm});
            continue;
        }
        try out.print(sh.sa, "{d: >2}) SIG{s}", .{ i, nm });
        col += 1;
        if (col == 5) {
            try out.append(sh.sa, '\n');
            col = 0;
        } else try out.append(sh.sa, '\t');
    }
    if (col != 0) try out.append(sh.sa, '\n');
    _ = sh.out(out.items);
}

fn bi_trap(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var plist = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-l")) {
            try print_signal_list(sh, false);
            return 0;
        } else if (std.mem.eql(u8, a, "-p")) {
            plist = true;
        } else if (std.mem.eql(u8, a, "-")) {
            break;
        } else {
            sh.bmsg("trap", "{s}: invalid option", .{a});
            sh.usage_msg("trap", "trap [-lp] [[arg] signal_spec ...]");
            return 2;
        }
    }
    const rest = argv[i..];
    if (rest.len == 0) {
        try print_traps(sh);
        return 0;
    }
    if (plist) {
        var out: std.ArrayList(u8) = .empty;
        for (rest) |spec| {
            var nb: [16]u8 = undefined;
            if (signals.parse(spec)) |n| {
                const nm = try std.fmt.allocPrint(sh.sa, "SIG{s}", .{signals.name_of(n, &nb)});
                if (n == 0) try print_one_trap(sh, &out, "EXIT", sh.trap_exit) else try print_one_trap(sh, &out, nm, sh.traps[n]);
            } else if (std.mem.eql(u8, spec, "ERR")) try print_one_trap(sh, &out, "ERR", sh.trap_err) else if (std.mem.eql(u8, spec, "DEBUG")) try print_one_trap(sh, &out, "DEBUG", sh.trap_debug) else if (std.mem.eql(u8, spec, "RETURN")) try print_one_trap(sh, &out, "RETURN", sh.trap_return);
        }
        _ = sh.out(out.items);
        return 0;
    }
    var action: ?[]const u8 = rest[0];
    var specs = rest[1..];
    const first_is_sig = blk: {
        if (rest.len == 1) break :blk true;
        if (std.mem.eql(u8, rest[0], "-")) break :blk false;
        if (signals.parse(rest[0]) != null and rest.len == 1) break :blk true;
        break :blk false;
    };
    if (first_is_sig) {
        action = null;
        specs = rest;
    } else if (std.mem.eql(u8, rest[0], "-")) {
        action = null;
    }
    var status: u8 = 0;
    for (specs) |sp| {
        if (!try set_trap(sh, sp, action)) status = 1;
    }
    return status;
}

fn bi_wait(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var any = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-n")) any = true else if (std.mem.eql(u8, a, "-f")) {} else {
            sh.bmsg("wait", "{s}: invalid option", .{a});
            sh.usage_msg("wait", "wait [-fn] [-p var] [id ...]");
            return 2;
        }
    }
    const ids = argv[i..];
    if (any) {
        var st: c_int = 0;
        while (true) {
            var any_live = false;
            for (sh.jobs.items) |*j| {
                if (!j.reaped and !j.disowned) any_live = true;
            }
            if (!any_live) return 127;
            const pid = sys.waitpid(-1, &st, 0);
            if (pid < 0) {
                if (sys.errno() == sys.EINTR) {
                    try exec.check_signals(sh);
                    continue;
                }
                return 127;
            }
            if (sh.find_job(pid)) |j| {
                j.reaped = true;
                j.done = true;
                j.status = sys.status_code(st);
                if (j.disowned) continue;
                const code = j.status;
                j.disowned = true;
                return code;
            }
        }
    }
    if (ids.len == 0) {
        for (sh.jobs.items) |*j| {
            if (j.reaped) continue;
            j.status = exec.wait_pid(sh, j.pid);
            j.reaped = true;
            j.done = true;
        }
        for (sh.jobs.items) |*j| j.disowned = true;
        return 0;
    }
    var status: u8 = 0;
    for (ids) |idtxt| {
        var pid: c_int = 0;
        if (idtxt.len > 0 and idtxt[0] == '%') {
            const n = std.fmt.parseInt(u32, idtxt[1..], 10) catch 0;
            var found = false;
            for (sh.jobs.items) |j| {
                if (j.id == n) {
                    pid = j.pid;
                    found = true;
                }
            }
            if (!found) {
                sh.bmsg("wait", "{s}: no such job", .{idtxt});
                status = 127;
                continue;
            }
        } else {
            pid = std.fmt.parseInt(c_int, idtxt, 10) catch {
                sh.bmsg("wait", "`{s}': not a pid or valid job spec", .{idtxt});
                status = 1;
                continue;
            };
        }
        if (sh.find_job(pid)) |j| {
            if (j.reaped) {
                status = j.status;
            } else {
                j.status = exec.wait_pid(sh, pid);
                j.reaped = true;
                j.done = true;
                status = j.status;
            }
            j.disowned = true;
        } else {
            sh.bmsg("wait", "pid {d} is not a child of this shell", .{pid});
            status = 127;
        }
    }
    return status;
}

fn bi_kill(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var sig: u32 = 15;
    var list_mode = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "-L")) {
            list_mode = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= argv.len) {
                sh.bmsg("kill", "{s}: option requires an argument", .{a});
                sh.usage_msg("kill", "kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]");
                return 2;
            }
            sig = signals.parse(argv[i]) orelse {
                sh.bmsg("kill", "{s}: invalid signal specification", .{argv[i]});
                return 1;
            };
        } else {
            sig = signals.parse(a[1..]) orelse {
                sh.bmsg("kill", "{s}: invalid signal specification", .{a[1..]});
                return 1;
            };
        }
    }
    if (list_mode) {
        if (i >= argv.len) {
            try print_signal_list(sh, false);
            return 0;
        }
        var out: std.ArrayList(u8) = .empty;
        var st: u8 = 0;
        for (argv[i..]) |s| {
            if (std.fmt.parseInt(u32, s, 10)) |n| {
                const nn = if (n > 128) n - 128 else n;
                var nb: [16]u8 = undefined;
                if (nn == 0 or nn > 64) {
                    sh.bmsg("kill", "{s}: invalid signal specification", .{s});
                    st = 1;
                    continue;
                }
                try out.print(sh.sa, "{s}\n", .{signals.name_of(nn, &nb)});
            } else |_| {
                if (signals.parse(s)) |n| {
                    try out.print(sh.sa, "{d}\n", .{n});
                } else {
                    sh.bmsg("kill", "{s}: invalid signal specification", .{s});
                    st = 1;
                }
            }
        }
        _ = sh.out(out.items);
        return st;
    }
    if (i >= argv.len) {
        sh.usage_msg("kill", "kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]");
        return 2;
    }
    var status: u8 = 0;
    for (argv[i..]) |t| {
        var pid: c_int = undefined;
        if (t.len > 0 and t[0] == '%') {
            const n = std.fmt.parseInt(u32, t[1..], 10) catch 0;
            var found: ?c_int = null;
            for (sh.jobs.items) |j| if (j.id == n or (t.len == 2 and (t[1] == '+' or t[1] == '%'))) {
                found = j.pid;
            };
            pid = found orelse {
                sh.bmsg("kill", "{s}: no such job", .{t});
                status = 1;
                continue;
            };
        } else {
            pid = std.fmt.parseInt(c_int, t, 10) catch {
                sh.bmsg("kill", "{s}: arguments must be process or job IDs", .{t});
                status = 1;
                continue;
            };
        }
        if (sys.kill(pid, @intCast(sig)) != 0) {
            const e = sys.errno();
            const m: []const u8 = if (e == 3) "No such process" else sys.msg_for(e);
            sh.bmsg("kill", "({d}) - {s}", .{ pid, m });
            status = 1;
        }
    }
    return status;
}

fn refresh_jobs(sh: *Shell) void {
    for (sh.jobs.items) |*j| {
        if (j.reaped) continue;
        var st: c_int = 0;
        const r = sys.waitpid(j.pid, &st, sys.WNOHANG);
        if (r == j.pid) {
            j.reaped = true;
            j.done = true;
            j.status = sys.status_code(st);
        }
    }
}

fn bi_jobs(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = argv;
    refresh_jobs(sh);
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (sh.jobs.items) |*j| {
        if (j.disowned) continue;
        n += 1;
    }
    var k: usize = 0;
    for (sh.jobs.items) |*j| {
        if (j.disowned) continue;
        k += 1;
        const mark: u8 = if (k == n) '+' else if (k + 1 == n) '-' else ' ';
        const state: []const u8 = if (j.done) (if (j.status == 0) "Done" else "Exit") else "Running";
        try out.print(sh.sa, "[{d}]{c}  {s: <24}{s}{s}\n", .{ j.id, mark, state, j.cmd, if (j.done) "" else " &" });
    }
    _ = sh.out(out.items);
    var w: usize = 0;
    while (w < sh.jobs.items.len) {
        if (sh.jobs.items[w].done) {
            _ = sh.jobs.orderedRemove(w);
        } else w += 1;
    }
    return 0;
}

fn bi_disown(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (argv.len <= 1 or (argv.len == 2 and (std.mem.eql(u8, argv[1], "-a") or std.mem.eql(u8, argv[1], "-r")))) {
        if (sh.jobs.items.len == 0 and argv.len <= 1) {
            sh.bmsg("disown", "current: no such job", .{});
            return 1;
        }
        sh.jobs.clearRetainingCapacity();
        return 0;
    }
    var status: u8 = 0;
    for (argv[1..]) |t| {
        if (std.mem.eql(u8, t, "-h")) continue;
        var found = false;
        for (sh.jobs.items, 0..) |j, idx| {
            const match = (t.len > 1 and t[0] == '%' and (std.fmt.parseInt(u32, t[1..], 10) catch 0) == j.id) or (std.fmt.parseInt(c_int, t, 10) catch -1) == j.pid;
            if (match) {
                _ = sh.jobs.orderedRemove(idx);
                found = true;
                break;
            }
        }
        if (!found) {
            sh.bmsg("disown", "{s}: no such job", .{t});
            status = 1;
        }
    }
    return status;
}

fn bi_fg(sh: *Shell, argv: []const []const u8) Err!u8 {
    sh.bmsg(argv[0], "no job control", .{});
    return 1;
}

fn bi_umask(sh: *Shell, argv: []const []const u8) Err!u8 {
    var symbolic = false;
    var print = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                'S' => symbolic = true,
                'p' => print = true,
                else => {
                    sh.bmsg("umask", "-{c}: invalid option", .{c});
                    sh.usage_msg("umask", "umask [-p] [-S] [mode]");
                    return 2;
                },
            }
        }
    }
    const cur = sys.umask(0);
    _ = sys.umask(cur);
    if (i >= argv.len) {
        if (symbolic) {
            const m = cur & 0o777;
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "u={s},g={s},o={s}\n", .{ perm_str(7 - ((m >> 6) & 7)), perm_str(7 - ((m >> 3) & 7)), perm_str(7 - (m & 7)) }) catch "";
            _ = sh.out(s);
        } else if (print) {
            _ = sh.outf("umask {o:0>4}\n", .{cur});
        } else _ = sh.outf("{o:0>4}\n", .{cur});
        return 0;
    }
    const arg = argv[i];
    if (arg.len > 0 and std.ascii.isDigit(arg[0])) {
        const v = std.fmt.parseInt(c_uint, arg, 8) catch {
            sh.bmsg("umask", "{s}: octal number out of range", .{arg});
            return 1;
        };
        if (v > 0o777) {
            sh.bmsg("umask", "{s}: octal number out of range", .{arg});
            return 1;
        }
        _ = sys.umask(v);
        return 0;
    }
    var m: c_uint = cur & 0o777;
    var parts_it = std.mem.splitScalar(u8, arg, ',');
    while (parts_it.next()) |part| {
        var k: usize = 0;
        var who: c_uint = 0;
        while (k < part.len and (part[k] == 'u' or part[k] == 'g' or part[k] == 'o' or part[k] == 'a')) : (k += 1) {
            who |= switch (part[k]) {
                'u' => 0o700,
                'g' => 0o070,
                'o' => 0o007,
                else => 0o777,
            };
        }
        if (who == 0) who = 0o777;
        if (k >= part.len or !(part[k] == '=' or part[k] == '+' or part[k] == '-')) {
            sh.bmsg("umask", "`{c}': invalid symbolic mode character", .{if (k < part.len) part[k] else ' '});
            return 1;
        }
        const op = part[k];
        k += 1;
        var bits: c_uint = 0;
        while (k < part.len) : (k += 1) {
            switch (part[k]) {
                'r' => bits |= 0o444,
                'w' => bits |= 0o222,
                'x' => bits |= 0o111,
                else => {
                    sh.bmsg("umask", "`{c}': invalid symbolic mode character", .{part[k]});
                    return 1;
                },
            }
        }
        bits &= who;
        switch (op) {
            '=' => m = (m | who) & ~bits,
            '+' => m &= ~bits,
            else => m |= bits,
        }
    }
    _ = sys.umask(m);
    return 0;
}

fn perm_str(p: c_uint) []const u8 {
    return switch (p) {
        0 => "",
        1 => "x",
        2 => "w",
        3 => "wx",
        4 => "r",
        5 => "rx",
        6 => "rw",
        else => "rwx",
    };
}

const Limit = struct { flag: u8, res: c_int, desc: []const u8, unit: []const u8, scale: u64 };
const limits = [_]Limit{
    .{ .flag = 'R', .res = 15, .desc = "real-time non-blocking time", .unit = "microseconds", .scale = 1 },
    .{ .flag = 'c', .res = 4, .desc = "core file size", .unit = "blocks", .scale = 512 },
    .{ .flag = 'd', .res = 2, .desc = "data seg size", .unit = "kbytes", .scale = 1024 },
    .{ .flag = 'e', .res = 13, .desc = "scheduling priority", .unit = "", .scale = 1 },
    .{ .flag = 'f', .res = 1, .desc = "file size", .unit = "blocks", .scale = 512 },
    .{ .flag = 'i', .res = 11, .desc = "pending signals", .unit = "", .scale = 1 },
    .{ .flag = 'l', .res = 8, .desc = "max locked memory", .unit = "kbytes", .scale = 1024 },
    .{ .flag = 'm', .res = 5, .desc = "max memory size", .unit = "kbytes", .scale = 1024 },
    .{ .flag = 'n', .res = 7, .desc = "open files", .unit = "", .scale = 1 },
    .{ .flag = 'p', .res = -1, .desc = "pipe size", .unit = "512 bytes", .scale = 1 },
    .{ .flag = 'q', .res = 12, .desc = "POSIX message queues", .unit = "bytes", .scale = 1 },
    .{ .flag = 'r', .res = 14, .desc = "real-time priority", .unit = "", .scale = 1 },
    .{ .flag = 's', .res = 3, .desc = "stack size", .unit = "kbytes", .scale = 1024 },
    .{ .flag = 't', .res = 0, .desc = "cpu time", .unit = "seconds", .scale = 1 },
    .{ .flag = 'u', .res = 6, .desc = "max user processes", .unit = "", .scale = 1 },
    .{ .flag = 'v', .res = 9, .desc = "virtual memory", .unit = "kbytes", .scale = 1024 },
    .{ .flag = 'x', .res = 10, .desc = "file locks", .unit = "", .scale = 1 },
};

fn get_limit(l: Limit, rl: *sys.RLimit) void {
    if (l.res < 0) {
        rl.* = .{ .cur = 8, .max = 8 };
        return;
    }
    _ = sys.getrlimit(l.res, rl);
}

fn bi_ulimit(sh: *Shell, argv: []const []const u8) Err!u8 {
    var hard = false;
    var soft = false;
    var all = false;
    var which: ?Limit = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                'H' => hard = true,
                'S' => soft = true,
                'a' => all = true,
                else => {
                    var f: ?Limit = null;
                    for (limits) |l| if (l.flag == c) {
                        f = l;
                    };
                    which = f orelse {
                        sh.bmsg("ulimit", "-{c}: invalid option", .{c});
                        sh.usage_msg("ulimit", "ulimit [-SHabcdefiklmnpqrstuvxPRT] [limit]");
                        return 2;
                    };
                },
            }
        }
    }
    if (all) {
        var out: std.ArrayList(u8) = .empty;
        for (limits) |l| {
            var rl: sys.RLimit = undefined;
            get_limit(l, &rl);
            const v = if (hard) rl.max else rl.cur;
            const unit_txt = if (l.unit.len > 0) try std.fmt.allocPrint(sh.sa, "({s}, -{c})", .{ l.unit, l.flag }) else try std.fmt.allocPrint(sh.sa, "(-{c})", .{l.flag});
            const pad = @max(@as(isize, 40) - @as(isize, @intCast(l.desc.len)) - @as(isize, @intCast(unit_txt.len)), 2);
            try out.appendSlice(sh.sa, l.desc);
            try out.appendNTimes(sh.sa, ' ', @intCast(pad));
            try out.appendSlice(sh.sa, unit_txt);
            if (v == std.math.maxInt(u64)) try out.appendSlice(sh.sa, " unlimited\n") else try out.print(sh.sa, " {d}\n", .{v / l.scale});
        }
        _ = sh.out(out.items);
        return 0;
    }
    const lim = which orelse limits[4];
    var rl: sys.RLimit = undefined;
    get_limit(lim, &rl);
    if (i >= argv.len) {
        const v = if (hard) rl.max else rl.cur;
        if (v == std.math.maxInt(u64)) _ = sh.out("unlimited\n") else _ = sh.outf("{d}\n", .{v / lim.scale});
        return 0;
    }
    if (lim.res < 0) {
        sh.bmsg("ulimit", "{s}: cannot modify limit: Invalid argument", .{lim.desc});
        return 1;
    }
    const arg = argv[i];
    var nv: u64 = undefined;
    if (std.mem.eql(u8, arg, "unlimited")) nv = std.math.maxInt(u64) else if (std.mem.eql(u8, arg, "hard")) nv = rl.max else if (std.mem.eql(u8, arg, "soft")) nv = rl.cur else {
        const n = std.fmt.parseInt(u64, arg, 10) catch {
            sh.bmsg("ulimit", "{s}: invalid number", .{arg});
            return 1;
        };
        nv = n * lim.scale;
    }
    if (hard or !soft) rl.max = nv;
    if (soft or !hard) rl.cur = nv;
    if (hard and !soft) {
        if (rl.cur > rl.max) rl.cur = rl.max;
    }
    if (sys.setrlimit(lim.res, &rl) != 0) {
        sh.bmsg("ulimit", "{s}: cannot modify limit: {s}", .{ lim.desc, sys.msg_for(sys.errno()) });
        return 1;
    }
    return 0;
}

fn bi_times(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = argv;
    var t: sys.Tms = undefined;
    _ = sys.times(&t);
    const hz: f64 = 100.0;
    const f = struct {
        fn m(x: c_long) struct { mi: u64, s: f64 } {
            const secs = @as(f64, @floatFromInt(x)) / 100.0;
            const mi: u64 = @intFromFloat(secs / 60.0);
            return .{ .mi = mi, .s = secs - @as(f64, @floatFromInt(mi)) * 60.0 };
        }
    }.m;
    _ = hz;
    const u = f(t.utime);
    const s = f(t.stime);
    const cu = f(t.cutime);
    const cs = f(t.cstime);
    _ = sh.outf("{d}m{d:.3}s {d}m{d:.3}s\n{d}m{d:.3}s {d}m{d:.3}s\n", .{ u.mi, u.s, s.mi, s.s, cu.mi, cu.s, cs.mi, cs.s });
    return 0;
}

fn bi_getopts(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (argv.len < 3) {
        sh.usage_msg("getopts", "getopts optstring name [arg ...]");
        return 2;
    }
    const optstring = argv[1];
    const name = argv[2];
    if (!Shell.is_valid_name(name)) {
        sh.bmsg("getopts", "`{s}': not a valid identifier", .{name});
        return 1;
    }
    const args: []const []const u8 = if (argv.len > 3) argv[3..] else @as([]const []const u8, @ptrCast(sh.pos.items));
    var optind: i64 = 1;
    if (sh.get_scalar("OPTIND")) |s| optind = std.fmt.parseInt(i64, s, 10) catch 1;
    if (optind < 1) optind = 1;
    if (optind != sh.getopts_expect) sh.optind_sub = 0;
    const silent = optstring.len > 0 and optstring[0] == ':';
    const opterr_on = blk: {
        if (sh.get_scalar("OPTERR")) |s| break :blk !std.mem.eql(u8, s, "0");
        break :blk true;
    };
    var done = false;
    var c: u8 = '?';
    var optarg: ?[]const u8 = null;
    var unset_optarg = true;
    const ai: usize = @intCast(optind - 1);
    if (ai >= args.len) {
        done = true;
    } else {
        const arg = args[ai];
        if (sh.optind_sub == 0) {
            if (arg.len < 2 or arg[0] != '-') {
                done = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                optind += 1;
                done = true;
            } else sh.optind_sub = 1;
        }
        if (!done) {
            const ch = arg[sh.optind_sub];
            sh.optind_sub += 1;
            const at_end = sh.optind_sub >= arg.len;
            const pos = if (ch == ':') null else std.mem.findScalar(u8, optstring, ch);
            if (pos == null) {
                c = '?';
                if (silent) {
                    optarg = &[_]u8{ch};
                    unset_optarg = false;
                } else if (opterr_on) {
                    sh.bmsg_noname("illegal option -- {c}", .{ch});
                }
                if (at_end) {
                    optind += 1;
                    sh.optind_sub = 0;
                }
            } else {
                c = ch;
                const needs = pos.? + 1 < optstring.len and optstring[pos.? + 1] == ':';
                if (needs) {
                    if (!at_end) {
                        optarg = arg[sh.optind_sub..];
                        unset_optarg = false;
                        optind += 1;
                        sh.optind_sub = 0;
                    } else if (ai + 1 < args.len) {
                        optarg = args[ai + 1];
                        unset_optarg = false;
                        optind += 2;
                        sh.optind_sub = 0;
                    } else {
                        optind += 1;
                        sh.optind_sub = 0;
                        if (silent) {
                            c = ':';
                            optarg = &[_]u8{ch};
                            unset_optarg = false;
                        } else {
                            c = '?';
                            if (opterr_on) sh.bmsg_noname("option requires an argument -- {c}", .{ch});
                        }
                    }
                } else if (at_end) {
                    optind += 1;
                    sh.optind_sub = 0;
                }
            }
        }
    }
    if (done) {
        sh.optind_sub = 0;
        c = '?';
    }
    sh.getopts_expect = optind;
    const ind_txt = try sh.tmp_fmt("{d}", .{optind});
    try sh.assign_scalar("OPTIND", ind_txt, false);
    if (unset_optarg) {
        _ = try sh.unset_var("OPTARG");
    } else try sh.assign_scalar("OPTARG", optarg.?, false);
    const ch_txt = [_]u8{c};
    try sh.assign_scalar(name, &ch_txt, false);
    return if (done) 1 else 0;
}

fn bi_let(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (argv.len < 2) {
        sh.bmsg("let", "expression expected", .{});
        return 1;
    }
    var last: i64 = 0;
    for (argv[1..]) |e| {
        last = arith.eval_string_ctx(sh, e, .let) catch |er| switch (er) {
            error.ArithError => return 1,
            else => return er,
        };
    }
    return if (last != 0) 0 else 1;
}

fn show_dirs_line(sh: *Shell, long: bool, per_line: bool, verbose: bool) Err!void {
    var out: std.ArrayList(u8) = .empty;
    const home = sh.get_scalar("HOME");
    const cwd = sh.get_scalar("PWD") orelse "";
    var all: std.ArrayList([]const u8) = .empty;
    try all.append(sh.sa, cwd);
    for (sh.dir_stack.items) |d| try all.append(sh.sa, d);
    for (all.items, 0..) |d, idx| {
        var shown: []const u8 = d;
        if (!long) {
            if (home) |h| {
                if (h.len > 0 and std.mem.startsWith(u8, d, h) and (d.len == h.len or d[h.len] == '/')) {
                    shown = try std.mem.concat(sh.sa, u8, &.{ "~", d[h.len..] });
                }
            }
        }
        if (verbose) {
            try out.print(sh.sa, "{d: >2}  {s}\n", .{ idx, shown });
        } else {
            try out.appendSlice(sh.sa, shown);
            try out.append(sh.sa, if (per_line or idx + 1 == all.items.len) '\n' else ' ');
        }
    }
    _ = sh.out(out.items);
}

fn bi_dirs(sh: *Shell, argv: []const []const u8) Err!u8 {
    var long = false;
    var per_line = false;
    var verbose = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-c")) {
            for (sh.dir_stack.items) |d| sh.gpa.free(d);
            sh.dir_stack.clearRetainingCapacity();
            return 0;
        } else if (std.mem.eql(u8, a, "-l")) long = true else if (std.mem.eql(u8, a, "-p")) per_line = true else if (std.mem.eql(u8, a, "-v")) verbose = true else {
            sh.bmsg("dirs", "{s}: invalid option", .{a});
            sh.usage_msg("dirs", "dirs [-clpv] [+N] [-N]");
            return 2;
        }
    }
    try show_dirs_line(sh, long, per_line, verbose);
    return 0;
}

fn bi_pushd(sh: *Shell, argv: []const []const u8) Err!u8 {
    var no_cd = false;
    var args: []const []const u8 = argv[1..];
    while (args.len > 0 and std.mem.eql(u8, args[0], "-n")) {
        no_cd = true;
        args = args[1..];
    }
    const cwd = try sh.sa.dupe(u8, sh.get_scalar("PWD") orelse "");
    if (args.len == 0) {
        if (sh.dir_stack.items.len == 0) {
            sh.bmsg("pushd", "no other directory", .{});
            return 1;
        }
        const top = sh.dir_stack.items[0];
        const topc = try sh.sa.dupe(u8, top);
        if (!try do_chdir(sh, "pushd", topc, false, false)) return 1;
        sh.gpa.free(sh.dir_stack.items[0]);
        sh.dir_stack.items[0] = try sh.gpa.dupe(u8, cwd);
    } else {
        const a = args[0];
        if ((a[0] == '+' or a[0] == '-') and a.len > 1 and std.ascii.isDigit(a[1])) {
            const n = std.fmt.parseInt(usize, a[1..], 10) catch 0;
            const total = sh.dir_stack.items.len + 1;
            if (n >= total) {
                sh.bmsg("pushd", "{s}: directory stack index out of range", .{a});
                return 1;
            }
            var all: std.ArrayList([]const u8) = .empty;
            try all.append(sh.sa, cwd);
            for (sh.dir_stack.items) |d| try all.append(sh.sa, try sh.sa.dupe(u8, d));
            const idx = if (a[0] == '+') n else total - 1 - n;
            std.mem.rotate([]const u8, all.items, idx);
            for (sh.dir_stack.items) |d| sh.gpa.free(d);
            sh.dir_stack.clearRetainingCapacity();
            for (all.items[1..]) |d| try sh.dir_stack.append(sh.gpa, try sh.gpa.dupe(u8, d));
            if (!try do_chdir(sh, "pushd", all.items[0], false, false)) return 1;
        } else {
            if (!no_cd) {
                if (!try do_chdir(sh, "pushd", a, false, false)) return 1;
            }
            try sh.dir_stack.insert(sh.gpa, 0, try sh.gpa.dupe(u8, if (no_cd) (sh.get_scalar("PWD") orelse "") else cwd));
            if (no_cd) {
                const full = try std.mem.concat(sh.sa, u8, &.{a});
                sh.gpa.free(sh.dir_stack.items[0]);
                sh.dir_stack.items[0] = try sh.gpa.dupe(u8, full);
            }
        }
    }
    try show_dirs_line(sh, false, false, false);
    return 0;
}

fn bi_popd(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (sh.dir_stack.items.len == 0) {
        sh.bmsg("popd", "directory stack empty", .{});
        return 1;
    }
    var no_cd = false;
    var idx: usize = 0;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-n")) no_cd = true else if ((a[0] == '+' or a[0] == '-') and a.len > 1 and std.ascii.isDigit(a[1])) {
            const n = std.fmt.parseInt(usize, a[1..], 10) catch 0;
            const total = sh.dir_stack.items.len + 1;
            if (n >= total) {
                sh.bmsg("popd", "{s}: directory stack index out of range", .{a});
                return 1;
            }
            idx = if (a[0] == '+') n else total - 1 - n;
        }
    }
    if (idx == 0) {
        const top = try sh.sa.dupe(u8, sh.dir_stack.items[0]);
        if (!no_cd) {
            if (!try do_chdir(sh, "popd", top, false, false)) return 1;
        }
        sh.gpa.free(sh.dir_stack.orderedRemove(0));
    } else {
        sh.gpa.free(sh.dir_stack.orderedRemove(idx - 1));
    }
    try show_dirs_line(sh, false, false, false);
    return 0;
}

fn bi_help(sh: *Shell, argv: []const []const u8) Err!u8 {
    if (argv.len > 1) {
        const n = argv[argv.len - 1];
        if (is_builtin(n)) {
            _ = sh.outf("{s}: {s}\n", .{ n, n });
            return 0;
        }
        sh.bmsg("help", "no help topics match `{s}'.  Try `help help' or `man -k {s}' or `info {s}'.", .{ n, n, n });
        return 1;
    }
    _ = sh.out("zash shell, version 0.0.1\n");
    return 0;
}

fn bi_history(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = sh;
    _ = argv;
    return 0;
}

fn bi_complete(sh: *Shell, argv: []const []const u8) Err!u8 {
    _ = sh;
    _ = argv;
    return 0;
}

fn bi_enable(sh: *Shell, argv: []const []const u8) Err!u8 {
    var disable = false;
    var list_all = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| {
            switch (c) {
                'n' => disable = true,
                'a' => list_all = true,
                'p', 's', 'f', 'd' => {},
                else => {
                    sh.bmsg("enable", "-{c}: invalid option", .{c});
                    sh.usage_msg("enable", "enable [-a] [-dnps] [-f filename] [name ...]");
                    return 2;
                },
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    if (i >= argv.len) {
        var names: std.ArrayList([]const u8) = .empty;
        if (disable) {
            for (disabled_buf[0..disabled_n]) |d| try names.append(sh.sa, d);
        } else {
            for (table.keys()) |k| if (!sh_disabled_check(k)) try names.append(sh.sa, k);
        }
        std.mem.sort([]const u8, names.items, {}, lessStr);
        for (names.items) |n| try out.print(sh.sa, "enable {s}{s}\n", .{ if (disable) "-n " else "", n });
        _ = sh.out(out.items);
        return 0;
    }
    var status: u8 = 0;
    for (argv[i..]) |n| {
        if (table.get(n) == null) {
            sh.bmsg("enable", "{s}: not a shell builtin", .{n});
            status = 1;
            continue;
        }
        if (disable) {
            if (!sh_disabled_check(n) and disabled_n < disabled_buf.len) {
                disabled_buf[disabled_n] = try sh.gpa.dupe(u8, n);
                disabled_n += 1;
            }
        } else {
            var k: usize = 0;
            while (k < disabled_n) {
                if (std.mem.eql(u8, disabled_buf[k], n)) {
                    disabled_buf[k] = disabled_buf[disabled_n - 1];
                    disabled_n -= 1;
                } else k += 1;
            }
        }
    }
    return status;
}

fn bi_caller(sh: *Shell, argv: []const []const u8) Err!u8 {
    var e: usize = 0;
    if (argv.len > 1) {
        e = std.fmt.parseInt(usize, argv[1], 10) catch {
            sh.bmsg("caller", "{s}: invalid number", .{argv[1]});
            sh.usage_msg("caller", "caller [expr]");
            return 2;
        };
    }
    const lines = (try expand.virtual_array(sh, "BASH_LINENO")).?;
    const srcs = (try expand.virtual_array(sh, "BASH_SOURCE")).?;
    if (argv.len <= 1) {
        if (lines.len == 0) return 1;
        const f: []const u8 = if (srcs.len > 1) srcs[1] else "NULL";
        _ = sh.outf("{s} {s}\n", .{ lines[0], f });
        return 0;
    }
    const funcs = (try expand.virtual_array(sh, "FUNCNAME")) orelse return 1;
    if (e + 1 >= funcs.len or e >= lines.len) return 1;
    const f: []const u8 = if (e + 1 < srcs.len) srcs[e + 1] else "NULL";
    _ = sh.outf("{s} {s} {s}\n", .{ lines[e], funcs[e + 1], f });
    return 0;
}

fn bi_compgen(sh: *Shell, argv: []const []const u8) Err!u8 {
    var i: usize = 1;
    var wordlist: ?[]const u8 = null;
    var actions: std.ArrayList([]const u8) = .empty;
    var prefix: ?[]const u8 = null;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        const c = a[1];
        switch (c) {
            'W' => {
                i += 1;
                if (i < argv.len) wordlist = argv[i];
            },
            'A' => {
                i += 1;
                if (i < argv.len) try actions.append(sh.sa, argv[i]);
            },
            'P', 'S', 'F', 'C', 'G', 'X' => i += 1,
            'v' => try actions.append(sh.sa, "variable"),
            'f' => try actions.append(sh.sa, "file"),
            'd' => try actions.append(sh.sa, "directory"),
            'b' => try actions.append(sh.sa, "builtin"),
            'c' => try actions.append(sh.sa, "command"),
            'a' => try actions.append(sh.sa, "alias"),
            'k' => try actions.append(sh.sa, "keyword"),
            else => {},
        }
        if (c == 'P' and i < argv.len) prefix = argv[i];
    }
    const word: []const u8 = if (i < argv.len) argv[i] else "";
    var out: std.ArrayList(u8) = .empty;
    var any = false;
    if (wordlist) |wl| {
        const exp = try expand_wordlist(sh, wl);
        for (exp) |w| {
            if (std.mem.startsWith(u8, w, word)) {
                try out.print(sh.sa, "{s}\n", .{w});
                any = true;
            }
        }
    }
    for (actions.items) |act| {
        var cands: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, act, "variable")) {
            var it = sh.vars.map.iterator();
            while (it.next()) |e| try cands.append(sh.sa, e.key_ptr.*);
        } else if (std.mem.eql(u8, act, "builtin")) {
            for (table.keys()) |k| try cands.append(sh.sa, k);
        } else if (std.mem.eql(u8, act, "function")) {
            var it = sh.funcs.iterator();
            while (it.next()) |e| try cands.append(sh.sa, e.key_ptr.*);
        } else if (std.mem.eql(u8, act, "keyword")) {
            for (keywords) |k| try cands.append(sh.sa, k);
        } else if (std.mem.eql(u8, act, "alias")) {
            var it = sh.aliases.iterator();
            while (it.next()) |e| try cands.append(sh.sa, e.key_ptr.*);
        }
        std.mem.sort([]const u8, cands.items, {}, lessStr);
        for (cands.items) |cand| {
            if (std.mem.startsWith(u8, cand, word)) {
                try out.print(sh.sa, "{s}\n", .{cand});
                any = true;
            }
        }
    }
    _ = sh.out(out.items);
    return if (any) 0 else 1;
}

fn expand_wordlist(sh: *Shell, wl: []const u8) Err![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const ifs = sh.ifs();
    var start: usize = 0;
    var i: usize = 0;
    while (i <= wl.len) : (i += 1) {
        if (i == wl.len or std.mem.findScalar(u8, ifs, wl[i]) != null) {
            if (i > start) try out.append(sh.sa, wl[start..i]);
            start = i + 1;
        }
    }
    return out.items;
}

test "table has builtins" {
    try std.testing.expect(lookup("echo") != null);
    try std.testing.expect(lookup("nonesuch") == null);
}

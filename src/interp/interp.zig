const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const vars_mod = @import("vars.zig");
const exec = @import("exec.zig");
const builtin = @import("builtin");

pub const Shell = shell.Shell;
pub const Err = shell.Err;

var orig_stack: sys.RLimit = .{ .cur = 0, .max = 0 };

pub fn restore_stack_limit() void {
    if (orig_stack.cur != 0) _ = sys.setrlimit(3, &orig_stack);
}

var stack_raised = false;

pub fn raise_stack_limit() void {
    if (stack_raised) return;
    stack_raised = true;
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
        if (std.mem.startsWith(u8, name, "BASH_FUNC_") and std.mem.endsWith(u8, name, "%%") and name.len > 12) {
            const fname = name["BASH_FUNC_".len .. name.len - 2];
            if (std.mem.startsWith(u8, value, "()")) {
                try sh.pending_funcs.put(gpa, try gpa.dupe(u8, fname), try gpa.dupe(u8, value));
            }
            continue;
        }
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
    if (sh.vars.get("PS1") == null) try set_plain(sh, "PS1", "\\s-\\v\\$ ");
    if (sh.vars.get("PS2") == null) try set_plain(sh, "PS2", "> ");
    if (sh.vars.get("PS4") == null) try set_plain(sh, "PS4", "+ ");
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

fn warn_script(sh: *Shell, lex: *const @import("../lexer.zig").Lexer, prefix: []const u8) void {
    for (lex.heredoc_warnings.items) |w| {
        sh.msg_raw("{s}: line {d}: warning: here-document at line {d} delimited by end-of-file (wanted `{s}')\n", .{ prefix, w.eof_line, w.op_line, w.delimiter });
    }
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
    if (src.len > 16384) raise_stack_limit();
    var arena = try sh.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(sh.gpa);
    try sh.keep_arenas.append(sh.gpa, arena);
    const a = arena.allocator();
    var p = parser.Parser.init(a, src, .{});
    const res = p.parse_script();
    if (res) |list| {
        warn_script(sh, &p.lex, label_prefix);
        if (sh.dash_c) exec.mark_final_list(sh, list);
        const st = try exec.run_top(sh, list, src);
        return finish(sh, st);
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            const err = p.lex.err.?;
            warn_script(sh, &p.lex, label_prefix);
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
            return finish(sh, if (err.kind == .eof_matching_only or err.in_array) 1 else 2);
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

fn expand_prompt(sh: *Shell, ps: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = sh.sa;
    var k: usize = 0;
    while (k < ps.len) : (k += 1) {
        const c = ps[k];
        if (c != '\\' or k + 1 >= ps.len) {
            out.append(a, c) catch return ps;
            continue;
        }
        k += 1;
        switch (ps[k]) {
            'u' => out.appendSlice(a, sh.get_or_empty("USER")) catch {},
            'h', 'H' => out.appendSlice(a, sh.get_or_empty("HOSTNAME")) catch {},
            'w' => {
                const pwd = sh.get_or_empty("PWD");
                const home = sh.get_or_empty("HOME");
                if (home.len > 0 and std.mem.startsWith(u8, pwd, home)) {
                    out.append(a, '~') catch {};
                    out.appendSlice(a, pwd[home.len..]) catch {};
                } else out.appendSlice(a, pwd) catch {};
            },
            'W' => {
                const pwd = sh.get_or_empty("PWD");
                const base = if (std.mem.findScalarLast(u8, pwd, '/')) |s| pwd[s + 1 ..] else pwd;
                out.appendSlice(a, if (base.len == 0) "/" else base) catch {};
            },
            '$' => out.append(a, if (sys.geteuid() == 0) '#' else '$') catch {},
            'n' => out.append(a, '\n') catch {},
            'r' => out.append(a, '\r') catch {},
            'e' => out.append(a, 27) catch {},
            's' => out.appendSlice(a, "zash") catch {},
            'v' => out.appendSlice(a, "0.0") catch {},
            'V' => out.appendSlice(a, "0.0.1") catch {},
            '[', ']' => {},
            '\\' => out.append(a, '\\') catch {},
            else => {
                out.append(a, '\\') catch {};
                out.append(a, ps[k]) catch {};
            },
        }
    }
    return out.items;
}

pub fn run_interactive(sh: *Shell) u8 {
    sh.interactive = true;
    var act: sys.SigAction = .{ .handler = @intFromPtr(&shell.signal_handler) };
    _ = sys.sigemptyset(&act.mask);
    _ = sys.sigaction(sys.SIGINT, &act, null);
    sys.set_signal(3, sys.SIG_IGN);
    sys.set_signal(15, sys.SIG_IGN);
    var pending: std.ArrayList(u8) = .empty;
    var status: u8 = 0;
    const gpa = sh.gpa;
    defer pending.deinit(gpa);
    while (true) {
        const m = sh.scratch.mark();
        const ps_name: []const u8 = if (pending.items.len == 0) "PS1" else "PS2";
        const prompt = expand_prompt(sh, sh.get_scalar(ps_name) orelse (if (pending.items.len == 0) "$ " else "> "));
        _ = sys.write_all(2, prompt);
        var line: std.ArrayList(u8) = .empty;
        var eof = false;
        var interrupted = false;
        while (true) {
            var b: [1]u8 = undefined;
            const n = sys.read(0, &b, 1);
            if (n < 0) {
                if (sys.errno() == sys.EINTR) {
                    interrupted = true;
                    break;
                }
                eof = true;
                break;
            }
            if (n == 0) {
                eof = true;
                break;
            }
            line.append(sh.sa, b[0]) catch {};
            if (b[0] == '\n') break;
        }
        if (interrupted) {
            _ = shell.pending_signals.swap(0, .seq_cst);
            _ = sys.write_all(2, "\n");
            pending.clearRetainingCapacity();
            sh.scratch.release(m);
            continue;
        }
        if (eof and line.items.len == 0 and pending.items.len == 0) {
            sh.scratch.release(m);
            _ = sys.write_all(2, "exit\n");
            break;
        }
        pending.appendSlice(gpa, line.items) catch break;
        sh.scratch.release(m);
        const holder = gpa.create(std.heap.ArenaAllocator) catch break;
        holder.* = std.heap.ArenaAllocator.init(gpa);
        const keep = holder.allocator().dupe(u8, pending.items) catch break;
        var p = parser.Parser.init(holder.allocator(), keep, .{});
        if (p.parse_script()) |list| {
            sh.keep_arenas.append(gpa, holder) catch {};
            if (exec.run_top(sh, list, keep)) |st| {
                status = st;
            } else |e| switch (e) {
                error.Exit => return finish(sh, sh.exit_status_pending orelse sh.status),
                else => status = sh.status,
            }
            sh.status = status;
            pending.clearRetainingCapacity();
        } else |e| {
            const err_opt = p.lex.err;
            holder.deinit();
            gpa.destroy(holder);
            switch (e) {
                error.OutOfMemory => break,
                error.Syntax => {
                    const err = err_opt.?;
                    const incomplete = err.kind == .unexpected_eof or err.kind == .eof_matching or err.kind == .eof_matching_only or err.kind == .eof_looking;
                    if (incomplete and !eof) continue;
                    var aw = std.Io.Writer.Allocating.init(sh.sa);
                    err.write(&aw.writer, "zash") catch {};
                    _ = sys.write_all(2, aw.written());
                    sh.status = 2;
                    status = 2;
                    pending.clearRetainingCapacity();
                },
            }
        }
        if (eof) break;
    }
    return finish(sh, status);
}

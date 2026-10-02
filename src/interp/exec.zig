const std = @import("std");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const redir = @import("redir.zig");
const builtins = @import("builtins.zig");
const cond = @import("cond.zig");
const arith = @import("arith.zig");
const unparse = @import("unparse.zig");
const strutil = @import("strutil.zig");
const plan = @import("plan.zig");
const registry = @import("../utils/registry.zig");
const common = @import("../utils/common.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Allocator = std.mem.Allocator;

pub const Pair = struct { key: ?[]const u8, idx: ?i64 = null, val: []const u8 };

pub const Expanded = struct {
    scalar: ?[]const u8 = null,
    sub_key: ?[]const u8 = null,
    sub_idx: ?i64 = null,
    pairs: ?[]const Pair = null,
};

pub const AssignItem = struct { a: ast.Assign, ex: Expanded };

pub const DeclItem = union(enum) {
    arg: []const u8,
    assign: AssignItem,
};

pub fn set_last_arg(sh: *Shell, s: []const u8) void {
    if (sh.last_arg_buf.len < s.len) {
        const nb = sh.gpa.alloc(u8, s.len + 32) catch return;
        if (sh.last_arg_buf.len > 0) sh.gpa.free(sh.last_arg_buf);
        sh.last_arg_buf = nb;
    }
    if (s.len > 0) @memcpy(sh.last_arg_buf[0..s.len], s);
    sh.last_arg = sh.last_arg_buf[0..s.len];
}

fn is_blank_or_comment(l: []const u8) bool {
    const t = std.mem.trim(u8, l, " \t\r");
    return t.len == 0 or t[0] == '#';
}

fn verbose_echo(sh: *Shell, src: []const u8, list: ast.List, idx: usize, next_line: *u32, base: u32) void {
    const item = list.items[idx];
    const iline: u32 = item.line -| base;
    var end_line: u32 = 0;
    if (idx + 1 < list.items.len and list.items[idx + 1].line > item.line) {
        end_line = list.items[idx + 1].line -| base -| 1;
    } else if (idx + 1 < list.items.len) {
        end_line = iline;
    } else {
        end_line = @intCast(std.mem.count(u8, src, "\n") + 1);
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| lines.append(sh.sa, l) catch return;
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    if (lines.items.len == 0) return;
    var e = @min(@as(usize, end_line), lines.items.len);
    while (e > iline and is_blank_or_comment(lines.items[e - 1])) e -= 1;
    var start: usize = @min(@max(iline, 1), lines.items.len);
    while (start > 1 and is_blank_or_comment(lines.items[start - 2])) start -= 1;
    var l: usize = @max(@as(usize, next_line.*), start);
    var out: std.ArrayList(u8) = .empty;
    while (l <= e) : (l += 1) {
        out.appendSlice(sh.sa, lines.items[l - 1]) catch return;
        out.append(sh.sa, '\n') catch return;
    }
    next_line.* = @intCast(e + 1);
    if (out.items.len > 0) _ = sys.write_all(2, out.items);
}

pub fn run_top(sh: *Shell, list: ast.List, src: []const u8) Err!u8 {
    var status: u8 = sh.status;
    var skip_line: u32 = 0;
    var next_line: u32 = 0;
    for (list.items, 0..) |item, idx| {
        if (skip_line != 0 and item.line == skip_line) continue;
        skip_line = 0;
        const m = sh.scratch.mark();
        if (sh.opt(.verbose)) verbose_echo(sh, src, list, idx, &next_line, 0);
        sh.scratch.release(m);
        status = run_item(sh, item) catch |e| switch (e) {
            error.Abort => {
                skip_line = item.line;
                status = sh.status;
                const ae = sh.abort_errexit;
                sh.abort_errexit = false;
                if (sh.opt(.errexit) and status != 0 and ae) {
                    sh.exit_status_pending = status;
                    return error.Exit;
                }
                continue;
            },
            else => return e,
        };
        try check_signals(sh);
    }
    return status;
}

pub fn run_list(sh: *Shell, list: ast.List) Err!u8 {
    var status: u8 = sh.status;
    for (list.items) |item| {
        status = try run_item(sh, item);
        if (pending_check(sh)) try check_signals(sh);
    }
    return status;
}

fn pending_check(_: *Shell) bool {
    return shell.pending_signals.load(.monotonic) != 0;
}

fn run_item(sh: *Shell, item: ast.Item) Err!u8 {
    if (sh.opt(.noexec)) return 0;
    if (item.background) return run_background(sh, item);
    return run_and_or(sh, item.and_or);
}

fn run_and_or(sh: *Shell, ao: ast.AndOr) Err!u8 {
    var st = try run_pipeline_ign(sh, ao.first, ao.rest.len > 0);
    for (ao.rest, 0..) |link, i| {
        const last = i + 1 == ao.rest.len;
        const go = (link.op == .and_if and st == 0) or (link.op == .or_if and st != 0);
        if (!go) continue;
        st = try run_pipeline_ign(sh, link.pipeline, !last);
    }
    return st;
}

fn run_pipeline_ign(sh: *Shell, p: ast.Pipeline, ignore: bool) Err!u8 {
    if (ignore) sh.noerrexit += 1;
    defer if (ignore) {
        sh.noerrexit -= 1;
    };
    return run_pipeline(sh, p);
}

pub fn errexit_check(sh: *Shell, status: u8) Err!void {
    if (status == 0 or sh.noerrexit > 0) return;
    if (sh.trap_err.kind == .cmd and !sh.trap_err.inherited and !sh.in_err_trap) {
        sh.in_err_trap = true;
        defer sh.in_err_trap = false;
        const saved = sh.status;
        sh.status = status;
        sh.eval_depth += 1;
        defer sh.eval_depth -= 1;
        try run_trap_text(sh, sh.trap_err.cmd, sh.lineno -| 1);
        sh.status = saved;
    }
    if (sh.opt(.errexit)) {
        sh.status = status;
        return error.Exit;
    }
}

fn set_pipestatus(sh: *Shell, st: []const u8) void {
    const n = @min(st.len, sh.pipestatus.len);
    @memcpy(sh.pipestatus[0..n], st[0..n]);
    sh.pipestatus_len = n;
}

fn run_pipeline(sh: *Shell, p: ast.Pipeline) Err!u8 {
    if (p.time != .none) return run_timed(sh, p);
    if (p.commands.len == 0) return 0;
    if (p.negate) sh.noerrexit += 1;
    defer if (p.negate) {
        sh.noerrexit -= 1;
    };
    var status: u8 = undefined;
    if (p.commands.len == 1) {
        const c = &p.commands[0];
        status = try run_command(sh, c, false);
        if (sh.pending_sig != 0) flush_sig_report(sh);
        switch (c.body) {
            .simple, .subshell, .arith_cmd, .cond => {
                const one = [_]u8{status};
                set_pipestatus(sh, &one);
            },
            else => {},
        }
        if (!p.negate) {
            sh.status = status;
            switch (c.body) {
                .simple, .subshell, .arith_cmd, .cond => try errexit_check(sh, status),
                else => {},
            }
        }
    } else {
        status = try run_multi(sh, p);
        if (!p.negate) {
            sh.status = status;
            try errexit_check(sh, status);
        }
    }
    if (p.negate) {
        status = if (status == 0) 1 else 0;
    }
    sh.status = status;
    return status;
}

fn fmt_time(out: *std.ArrayList(u8), a: std.mem.Allocator, secs: f64, prec: u32, long: bool) !void {
    const p: u32 = @min(prec, 3);
    if (long) {
        const mins: u64 = @intFromFloat(secs / 60.0);
        const rem = secs - @as(f64, @floatFromInt(mins)) * 60.0;
        try out.print(a, "{d}m", .{mins});
        try print_fixed(out, a, rem, p);
        try out.append(a, 's');
    } else try print_fixed(out, a, secs, p);
}

fn print_fixed(out: *std.ArrayList(u8), a: std.mem.Allocator, v: f64, p: u32) !void {
    switch (p) {
        0 => try out.print(a, "{d:.0}", .{v}),
        1 => try out.print(a, "{d:.1}", .{v}),
        2 => try out.print(a, "{d:.2}", .{v}),
        else => try out.print(a, "{d:.3}", .{v}),
    }
}

fn run_timed(sh: *Shell, p: ast.Pipeline) Err!u8 {
    const t0 = sys.mono_ns();
    var tms0: sys.Tms = undefined;
    _ = sys.times(&tms0);
    var np = p;
    np.time = .none;
    const st = if (p.commands.len == 0) @as(u8, 0) else try run_pipeline(sh, np);
    const t1 = sys.mono_ns();
    var tms1: sys.Tms = undefined;
    _ = sys.times(&tms1);
    const el = @as(f64, @floatFromInt(t1 - t0)) / 1e9;
    const hz: f64 = 100.0;
    const ut = @as(f64, @floatFromInt(tms1.cutime - tms0.cutime + tms1.utime - tms0.utime)) / hz;
    const stt = @as(f64, @floatFromInt(tms1.cstime - tms0.cstime + tms1.stime - tms0.stime)) / hz;
    var fmt_text: []const u8 = "\nreal\t%3lR\nuser\t%3lU\nsys\t%3lS";
    if (p.time == .time_posix) fmt_text = "real %2R\nuser %2U\nsys %2S";
    if (p.time != .time_posix) {
        if (sh.vars.get("TIMEFORMAT")) |v| {
            if (sh.scalar_of(v)) |s| fmt_text = s;
        }
    }
    if (fmt_text.len == 0) return st;
    var out: std.ArrayList(u8) = .empty;
    const a = sh.sa;
    var i: usize = 0;
    while (i < fmt_text.len) : (i += 1) {
        const c = fmt_text[i];
        if (c != '%' or i + 1 >= fmt_text.len) {
            try out.append(a, c);
            continue;
        }
        i += 1;
        var prec: u32 = 3;
        var long = false;
        if (std.ascii.isDigit(fmt_text[i])) {
            prec = fmt_text[i] - '0';
            i += 1;
        }
        if (i < fmt_text.len and fmt_text[i] == 'l') {
            long = true;
            i += 1;
        }
        if (i >= fmt_text.len) break;
        switch (fmt_text[i]) {
            'R' => try fmt_time(&out, a, el, prec, long),
            'U' => try fmt_time(&out, a, ut, prec, long),
            'S' => try fmt_time(&out, a, stt, prec, long),
            'P' => {
                const pct = if (el > 0) (ut + stt) / el * 100.0 else 0.0;
                try out.print(a, "{d:.2}", .{pct});
            },
            '%' => try out.append(a, '%'),
            else => {
                try out.append(a, '%');
                try out.append(a, fmt_text[i]);
            },
        }
    }
    try out.append(a, '\n');
    _ = sys.write_all(2, out.items);
    return st;
}

fn run_multi(sh: *Shell, p: ast.Pipeline) Err!u8 {
    const a = sh.sa;
    const n = p.commands.len;
    const pipes = try a.alloc([2]c_int, n - 1);
    const pids = try a.alloc(c_int, n);
    @memset(pids, -1);
    var made: usize = 0;
    errdefer for (pipes[0..made]) |pp| {
        _ = sys.close(pp[0]);
        _ = sys.close(pp[1]);
    };
    for (pipes) |*pp| {
        if (sys.pipe(pp) != 0) {
            sh.msg("pipe: {s}", .{sys.msg_for(sys.errno())});
            return error.Abort;
        }
        made += 1;
    }
    const lastpipe = sh.shopt(.lastpipe) and !sh.opt(.monitor);
    var forked_upto = n;
    if (lastpipe) forked_upto = n - 1;
    var i: usize = 0;
    while (i < forked_upto) : (i += 1) {
        const pid = sys.fork();
        if (pid < 0) {
            sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
            break;
        }
        if (pid == 0) {
            if (i > 0) _ = sys.dup2(pipes[i - 1][0], 0);
            if (i < n - 1) {
                _ = sys.dup2(pipes[i][1], 1);
                if (i < p.pipe_stderr.len and p.pipe_stderr[i]) _ = sys.dup2(pipes[i][1], 2);
            }
            for (pipes) |pp| {
                _ = sys.close(pp[0]);
                _ = sys.close(pp[1]);
            }
            enter_child(sh);
            const st = child_body(sh, &p.commands[i]);
            child_exit(sh, st);
        }
        pids[i] = pid;
        if (i > 0) _ = sys.close(pipes[i - 1][0]);
        if (i < n - 1) _ = sys.close(pipes[i][1]);
    }
    made = 0;
    var last_status: u8 = 0;
    if (lastpipe) {
        const saved_in = sys.fcntl(0, sys.F_DUPFD_CLOEXEC, @as(c_int, 10));
        _ = sys.dup2(pipes[n - 2][0], 0);
        _ = sys.close(pipes[n - 2][0]);
        last_status = run_command(sh, &p.commands[n - 1], false) catch |e| {
            if (saved_in >= 0) {
                _ = sys.dup2(saved_in, 0);
                _ = sys.close(saved_in);
            }
            return e;
        };
        if (saved_in >= 0) {
            _ = sys.dup2(saved_in, 0);
            _ = sys.close(saved_in);
        }
    }
    const sts = try a.alloc(u8, n);
    for (0..n) |k| {
        if (pids[k] < 0) {
            sts[k] = if (lastpipe and k == n - 1) last_status else 127;
            continue;
        }
        sts[k] = wait_pid(sh, pids[k]);
    }
    set_pipestatus(sh, sts);
    var result = sts[n - 1];
    if (sh.opt(.pipefail)) {
        var k = n;
        while (k > 0) {
            k -= 1;
            if (sts[k] != 0) {
                result = sts[k];
                break;
            }
        }
    }
    return result;
}

pub fn wait_raw(sh: *Shell, pid: c_int) ?c_int {
    var st: c_int = 0;
    while (true) {
        const r = sys.waitpid(pid, &st, 0);
        if (r < 0) {
            if (sys.errno() == sys.EINTR) {
                check_signals(sh) catch {};
                continue;
            }
            return null;
        }
        break;
    }
    return st;
}

pub fn wait_pid(sh: *Shell, pid: c_int) u8 {
    const st = wait_raw(sh, pid) orelse return 127;
    return sys.status_code(st);
}

pub fn wait_report(sh: *Shell, pid: c_int) u8 {
    const st = wait_raw(sh, pid) orelse return 127;
    if (sys.wifsignaled(st) and sh.cmdsub_depth == 0) {
        const sig = sys.wtermsig(st);
        if (sig != sys.SIGINT and sig != sys.SIGPIPE) sh.pending_sig = st;
    }
    return sys.status_code(st);
}

fn flush_sig_report(sh: *Shell) void {
    const st = sh.pending_sig;
    if (st == 0) return;
    sh.pending_sig = 0;
    var buf: [128]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ std.mem.span(sys.strsignal(sys.wtermsig(st))), if (st & 0x80 != 0) " (core dumped)" else "" }) catch "";
    _ = sys.write_all(2, txt);
}

pub fn enter_child(sh: *Shell) void {
    sh.in_subshell = true;
    sh.subshell_level += 1;
    sh.bashpid = sys.getpid();
    reset_traps_for_child(sh);
}

fn reset_traps_for_child(sh: *Shell) void {
    var i: usize = 1;
    while (i < shell.nsig) : (i += 1) {
        if (sh.traps[i].kind == .cmd) {
            sys.set_signal(@intCast(i), sys.SIG_DFL);
            sh.traps[i].inherited = true;
        }
    }
    if (sh.trap_exit.kind == .cmd) sh.trap_exit.inherited = true;
    if (sh.trap_err.kind == .cmd) sh.trap_err.inherited = true;
    if (sh.trap_debug.kind == .cmd) sh.trap_debug.inherited = true;
    if (sh.trap_return.kind == .cmd) sh.trap_return.inherited = true;
    shell.pending_signals.store(0, .seq_cst);
}

pub fn child_exit(sh: *Shell, status: u8) noreturn {
    var st = status;
    if (sh.trap_exit.kind == .cmd and !sh.trap_exit.inherited) {
        const cmd = sh.trap_exit.cmd;
        sh.trap_exit = .{};
        sh.status = st;
        run_trap_text(sh, cmd, 0) catch {};
        st = sh.status;
        if (sh.exit_status_pending) |x| st = x;
    }
    sys._exit(st);
}

fn child_body(sh: *Shell, c: *const ast.Command) u8 {
    const st = run_command(sh, c, true) catch |e| switch (e) {
        error.Exit, error.Abort => sh.status,
        error.Return => sh.status,
        error.Break, error.Continue, error.ArithError => sh.status,
        error.OutOfMemory => 1,
    };
    return st;
}

pub fn run_command(sh: *Shell, c: *const ast.Command, final: bool) Err!u8 {
    switch (c.body) {
        .simple => |s| return run_simple(sh, c, s, final),
        else => {},
    }
    sh.lineno = c.line;
    if (c.redirs.len == 0) return run_body(sh, c, final);
    var scope: redir.Scope = .{};
    defer scope.restore(sh);
    if (!try redir.apply(sh, c.redirs, &scope)) {
        sh.status = 1;
        return 1;
    }
    return run_body(sh, c, final);
}

fn run_body(sh: *Shell, c: *const ast.Command, final: bool) Err!u8 {
    _ = final;
    switch (c.body) {
        .simple => unreachable,
        .subshell => |l| return run_subshell(sh, l),
        .group => |l| return run_list(sh, l),
        .if_cmd => |i| return run_if(sh, i),
        .loop => |l| return run_while(sh, l),
        .for_in => |f| return run_for(sh, f),
        .arith_for => |f| return run_arith_for(sh, f),
        .select => |f| return run_select(sh, f),
        .case => |cs| return run_case(sh, cs),
        .function => |f| return define_function(sh, f, c),
        .cond => |cd| return run_cond(sh, cd, c),
        .arith_cmd => |n| return run_arith_cmd(sh, n, c),
        .coproc => |cp| return run_coproc(sh, cp),
    }
}

fn define_function(sh: *Shell, f: ast.Function, c: *const ast.Command) Err!u8 {
    if (sh.funcs.get(f.name)) |old| {
        if (old.readonly) {
            sh.msg("{s}: readonly function", .{f.name});
            return 1;
        }
        old.body = f.body;
        old.file = sh.cur_file;
        old.line = c.line;
        sh.func_gen +%= 1;
        return 0;
    }
    const fn_ = try sh.gpa.create(shell.Func);
    errdefer sh.gpa.destroy(fn_);
    const name = try sh.gpa.dupe(u8, f.name);
    fn_.* = .{ .name = name, .body = f.body, .file = sh.cur_file, .line = c.line };
    try sh.funcs.put(sh.gpa, name, fn_);
    sh.func_gen +%= 1;
    return 0;
}

fn run_subshell(sh: *Shell, l: ast.List) Err!u8 {
    const pid = sys.fork();
    if (pid < 0) {
        sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
        return 1;
    }
    if (pid == 0) {
        enter_child(sh);
        const single = single_simple(l);
        const st = (if (single) |cmd| run_command(sh, cmd, true) else run_list(sh, l)) catch |e| switch (e) {
            error.OutOfMemory => 1,
            else => sh.status,
        };
        child_exit(sh, st);
    }
    return wait_report(sh, pid);
}

fn single_simple(l: ast.List) ?*const ast.Command {
    if (l.items.len != 1) return null;
    const it = l.items[0];
    if (it.background or it.and_or.rest.len != 0) return null;
    const p = it.and_or.first;
    if (p.negate or p.time != .none or p.commands.len != 1) return null;
    if (p.commands[0].body != .simple) return null;
    return &p.commands[0];
}

fn run_cond_list(sh: *Shell, l: ast.List) Err!u8 {
    sh.noerrexit += 1;
    defer sh.noerrexit -= 1;
    return run_list(sh, l);
}

fn run_if(sh: *Shell, i: ast.If) Err!u8 {
    for (i.clauses) |cl| {
        const st = try run_cond_list(sh, cl.cond);
        if (st == 0) return run_list(sh, cl.body);
    }
    if (i.else_body) |e| return run_list(sh, e);
    return 0;
}

const LoopCtl = enum { normal, brk, cont };

fn catch_loop(sh: *Shell, r: Err!u8) Err!struct { st: u8, ctl: LoopCtl } {
    const st = r catch |e| switch (e) {
        error.Break => {
            sh.ctl_n -= 1;
            if (sh.ctl_n > 0) return error.Break;
            return .{ .st = sh.status, .ctl = .brk };
        },
        error.Continue => {
            sh.ctl_n -= 1;
            if (sh.ctl_n > 0) return error.Continue;
            return .{ .st = sh.status, .ctl = .cont };
        },
        else => return e,
    };
    return .{ .st = st, .ctl = .normal };
}

fn run_while(sh: *Shell, l: ast.Loop) Err!u8 {
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var status: u8 = 0;
    while (true) {
        const c = try catch_loop(sh, run_cond_list(sh, l.cond));
        if (c.ctl == .brk) break;
        const cst = c.st;
        if (c.ctl == .cont) continue;
        if (l.until) {
            if (cst == 0) break;
        } else if (cst != 0) break;
        const b = try catch_loop(sh, run_list(sh, l.body));
        status = b.st;
        if (b.ctl == .brk) break;
    }
    return status;
}

fn bad_loop_name(sh: *Shell, name: []const u8) Err {
    sh.msg("`{s}': not a valid identifier", .{name});
    sh.status = 1;
    sh.exit_status_pending = 1;
    return error.Exit;
}

fn run_for(sh: *Shell, f: ast.ForIn) Err!u8 {
    if (!Shell.is_valid_name(f.name)) return bad_loop_name(sh, f.name);
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    var items: std.ArrayList([]const u8) = .empty;
    if (f.words) |ws| {
        try expand.words_fields(sh, ws, &items);
    } else {
        for (sh.pos.items) |p| try items.append(sh.sa, try sh.sa.dupe(u8, p));
    }
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var status: u8 = 0;
    for (items.items) |it| {
        sh.lineno = sh.lineno;
        if (sh.opt(.xtrace)) try trace_for(sh, "for", f.name, f.words);
        try sh.assign_scalar(f.name, it, false);
        const b = try catch_loop(sh, run_list(sh, f.body));
        status = b.st;
        if (b.ctl == .brk) break;
    }
    return status;
}

fn trace_for(sh: *Shell, kw: []const u8, name: []const u8, words: ?[]const ast.Word) Err!void {
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    var w: std.ArrayList(u8) = .empty;
    try ps4(sh, &w);
    try w.print(sh.sa, "{s} {s} in", .{ kw, name });
    if (words) |ws| {
        for (ws) |wd| {
            try w.append(sh.sa, ' ');
            try w.appendSlice(sh.sa, try unparse.word_source(sh, wd));
        }
    } else try w.appendSlice(sh.sa, " \"$@\"");
    try w.append(sh.sa, '\n');
    _ = sys.write_all(2, w.items);
}

fn eval_arith_node(sh: *Shell, n: *const ast.Arith, ctx: arith.Ctx) Err!?i64 {
    return arith.eval_node(sh, n, ctx, "") catch |e| switch (e) {
        error.ArithError => return null,
        else => return e,
    };
}

fn trace_arith(sh: *Shell, n: *const ast.Arith) Err!void {
    var w: std.ArrayList(u8) = .empty;
    try ps4(sh, &w);
    try w.appendSlice(sh.sa, "(( ");
    try arith.render(sh, n, &w);
    try w.appendSlice(sh.sa, " ))\n");
    _ = sys.write_all(2, w.items);
}

fn run_arith_for(sh: *Shell, f: ast.ArithFor) Err!u8 {
    const tr = sh.opt(.xtrace);
    if (f.init) |n| {
        if (tr) try trace_arith(sh, n);
        _ = (try eval_arith_node(sh, n, .command)) orelse return 1;
    }
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var status: u8 = 0;
    while (true) {
        if (f.cond) |n| {
            if (tr) try trace_arith(sh, n);
            const v = (try eval_arith_node(sh, n, .command)) orelse return 1;
            if (v == 0) break;
        }
        const b = try catch_loop(sh, run_list(sh, f.body));
        status = b.st;
        if (b.ctl == .brk) break;
        if (f.step) |n| {
            if (tr) try trace_arith(sh, n);
            _ = (try eval_arith_node(sh, n, .command)) orelse return 1;
        }
    }
    return status;
}

fn run_select(sh: *Shell, f: ast.ForIn) Err!u8 {
    if (!Shell.is_valid_name(f.name)) return bad_loop_name(sh, f.name);
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    var items: std.ArrayList([]const u8) = .empty;
    if (f.words) |ws| {
        try expand.words_fields(sh, ws, &items);
    } else {
        for (sh.pos.items) |p| try items.append(sh.sa, try sh.sa.dupe(u8, p));
    }
    if (items.items.len == 0) return 0;
    sh.loop_depth += 1;
    defer sh.loop_depth -= 1;
    var status: u8 = 0;
    var show = true;
    while (true) {
        if (sh.opt(.xtrace)) try trace_for(sh, "select", f.name, f.words);
        if (show) {
            var out: std.ArrayList(u8) = .empty;
            const cols_s = sh.get_scalar("COLUMNS");
            const term_cols: usize = if (cols_s) |c| std.fmt.parseInt(usize, c, 10) catch 80 else 80;
            var max_elem: usize = 0;
            for (items.items) |it| max_elem = @max(max_elem, strutil.char_len(sh.utf8, it));
            const list_len = items.items.len;
            const indices_len = digits_of(list_len);
            max_elem += indices_len + 2 + 2;
            var cols: usize = if (max_elem > 0) term_cols / max_elem else 1;
            if (cols == 0) cols = 1;
            var rows: usize = list_len / cols + @intFromBool(list_len % cols != 0);
            cols = list_len / rows + @intFromBool(list_len % rows != 0);
            if (rows == 1) {
                rows = cols;
                cols = 1;
            }
            const first_indices_len = digits_of(rows);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                var ind = row;
                var pos: usize = 0;
                while (true) {
                    const il: usize = if (pos == 0) first_indices_len else indices_len;
                    const num = try std.fmt.allocPrint(sh.sa, "{d: >[2]}) {s}", .{ ind + 1, items.items[ind], il });
                    try out.appendSlice(sh.sa, num);
                    const elem_len = strutil.char_len(sh.utf8, items.items[ind]) + il + 2;
                    ind += rows;
                    if (ind >= list_len) break;
                    var from = pos + elem_len;
                    const to = pos + max_elem;
                    while (from < to) {
                        if (to / 8 > from / 8) {
                            try out.append(sh.sa, '\t');
                            from += 8 - (from % 8);
                        } else {
                            try out.append(sh.sa, ' ');
                            from += 1;
                        }
                    }
                    pos += max_elem;
                }
                try out.append(sh.sa, '\n');
            }
            _ = sys.write_all(2, out.items);
        }
        const ps3 = sh.get_scalar("PS3") orelse "#? ";
        _ = sys.write_all(2, ps3);
        var line: std.ArrayList(u8) = .empty;
        const got = builtins.read_line_fd(sh, 0, &line, '\n');
        if (!got and line.items.len == 0) return 1;
        try sh.assign_scalar("REPLY", line.items, false);
        const trimmed = std.mem.trim(u8, line.items, " \t\n");
        if (trimmed.len == 0) {
            show = true;
            continue;
        }
        show = false;
        const num = std.fmt.parseInt(usize, trimmed, 10) catch 0;
        if (num >= 1 and num <= items.items.len) {
            try sh.assign_scalar(f.name, items.items[num - 1], false);
        } else try sh.assign_scalar(f.name, "", false);
        const b = try catch_loop(sh, run_list(sh, f.body));
        status = b.st;
        if (b.ctl == .brk) break;
        if (!got) break;
    }
    return status;
}

fn digits_of(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn run_case(sh: *Shell, cs: ast.Case) Err!u8 {
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    if (sh.opt(.xtrace)) {
        var w: std.ArrayList(u8) = .empty;
        try ps4(sh, &w);
        try w.appendSlice(sh.sa, "case ");
        try w.appendSlice(sh.sa, try unparse.word_source(sh, cs.word));
        try w.appendSlice(sh.sa, " in\n");
        _ = sys.write_all(2, w.items);
    }
    const word = try expand.word_string(sh, cs.word);
    const o: @import("pattern.zig").Opts = .{ .extglob = true, .nocase = sh.shopt(.nocasematch) };
    var status: u8 = 0;
    var i: usize = 0;
    var fall = false;
    while (i < cs.clauses.len) : (i += 1) {
        const cl = cs.clauses[i];
        var matched = fall;
        if (!matched) {
            for (cl.patterns) |pw| {
                const pm = sh.scratch.mark();
                const pat = try expand.word_pattern(sh, pw);
                matched = @import("pattern.zig").match(sh.sa, pat, word, o);
                sh.scratch.release(pm);
                if (matched) break;
            }
        }
        if (!matched) continue;
        status = try run_list(sh, cl.body);
        switch (cl.term) {
            .break_ => return status,
            .fallthrough => fall = true,
            .test_next => fall = false,
        }
    }
    return status;
}

fn run_cond(sh: *Shell, cd: *const ast.Cond, c: *const ast.Command) Err!u8 {
    _ = c;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const r = cond.eval(sh, cd) catch |e| switch (e) {
        error.ArithError => return 2,
        else => return e,
    };
    return if (r) 0 else 1;
}

fn run_arith_cmd(sh: *Shell, n: *const ast.Arith, c: *const ast.Command) Err!u8 {
    _ = c;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    if (sh.opt(.xtrace)) {
        var w: std.ArrayList(u8) = .empty;
        try ps4(sh, &w);
        try w.appendSlice(sh.sa, "((  ");
        try arith.render(sh, n, &w);
        try w.appendSlice(sh.sa, "  ))\n");
        _ = sys.write_all(2, w.items);
    }
    const v = (try eval_arith_node(sh, n, .command)) orelse return 1;
    return if (v != 0) 0 else 1;
}

fn run_coproc(sh: *Shell, cp: ast.Coproc) Err!u8 {
    var in_p: [2]c_int = undefined;
    var out_p: [2]c_int = undefined;
    if (sys.pipe(&in_p) != 0 or sys.pipe(&out_p) != 0) return 1;
    const pid = sys.fork();
    if (pid == 0) {
        _ = sys.dup2(in_p[0], 0);
        _ = sys.dup2(out_p[1], 1);
        _ = sys.close(in_p[0]);
        _ = sys.close(in_p[1]);
        _ = sys.close(out_p[0]);
        _ = sys.close(out_p[1]);
        enter_child(sh);
        const st = child_body(sh, cp.body);
        child_exit(sh, st);
    }
    _ = sys.close(in_p[0]);
    _ = sys.close(out_p[1]);
    const name = cp.name orelse "COPROC";
    const rfd = sys.fcntl(out_p[0], sys.F_DUPFD, @as(c_int, 10));
    const wfd = sys.fcntl(in_p[1], sys.F_DUPFD, @as(c_int, 10));
    _ = sys.close(out_p[0]);
    _ = sys.close(in_p[1]);
    const v = sh.find(name) orelse try sh.new_var(name);
    try sh.declare_indexed(v);
    try sh.assign_indexed(v, 0, try sh.tmp_fmt("{d}", .{rfd}), false);
    try sh.assign_indexed(v, 1, try sh.tmp_fmt("{d}", .{wfd}), false);
    const pidname = try sh.tmp_fmt("{s}_PID", .{name});
    try sh.assign_scalar(pidname, try sh.tmp_fmt("{d}", .{pid}), false);
    sh.last_bg = pid;
    try sh.add_job(pid, "coproc");
    return 0;
}

pub fn ps4(sh: *Shell, w: *std.ArrayList(u8)) Err!void {
    const raw = sh.get_scalar("PS4") orelse (if (sh.vars.get("PS4") == null) "+ " else "");
    var text: []const u8 = raw;
    if (std.mem.findAny(u8, raw, "$`") != null) {
        text = try expand_dq_text(sh, raw);
    }
    if (text.len > 0) {
        var lvl: u32 = 0;
        while (lvl + 1 < sh.xtrace_level()) : (lvl += 1) try w.append(sh.sa, text[0]);
    }
    try w.appendSlice(sh.sa, text);
}

pub fn expand_dq_text(sh: *Shell, raw: []const u8) Err![]const u8 {
    var esc: std.ArrayList(u8) = .empty;
    try esc.appendSlice(sh.sa, ": \"");
    for (raw) |c| {
        if (c == '"') try esc.append(sh.sa, '\\');
        try esc.append(sh.sa, c);
    }
    try esc.append(sh.sa, '"');
    switch (parser.parse(sh.sa, esc.items, .{})) {
        .err => return raw,
        .ok => |l| {
            if (l.items.len == 0) return raw;
            const cmd = l.items[0].and_or.first.commands[0];
            if (cmd.body != .simple or cmd.body.simple.words.len < 2) return raw;
            return expand.word_string(sh, cmd.body.simple.words[1]);
        },
    }
}

fn xtrace_decl(sh: *Shell, s: ast.Simple, items: []const DeclItem, assign_vals: []const []const u8) Err!void {
    var w: std.ArrayList(u8) = .empty;
    var assoc_flag = false;
    for (items) |it| {
        switch (it) {
            .arg => |a| if (a.len > 1 and a[0] == '-' and std.mem.findScalar(u8, a, 'A') != null) {
                assoc_flag = true;
            },
            else => {},
        }
    }
    for (items) |it| {
        switch (it) {
            .assign => |as| if (as.ex.pairs) |pairs| {
                var is_assoc = assoc_flag;
                if (sh.find(as.a.name)) |v| {
                    if (v.value == .assoc) is_assoc = true;
                }
                try ps4(sh, &w);
                try trace_pairs(sh, &w, as.a.name, as.a.append, pairs, is_assoc);
                try w.append(sh.sa, '\n');
            },
            else => {},
        }
    }
    for (s.assigns, 0..) |as, i| {
        try ps4(sh, &w);
        try w.appendSlice(sh.sa, as.name);
        try w.append(sh.sa, '=');
        if (i < assign_vals.len and assign_vals[i].len > 0) try strutil.quote_xtrace_u(sh.sa, &w, assign_vals[i], sh.utf8);
        try w.append(sh.sa, '\n');
    }
    try ps4(sh, &w);
    for (items, 0..) |it, i| {
        if (i > 0) try w.append(sh.sa, ' ');
        switch (it) {
            .arg => |a| try strutil.quote_xtrace_u(sh.sa, &w, a, sh.utf8),
            .assign => |as| {
                var tok: std.ArrayList(u8) = .empty;
                try tok.appendSlice(sh.sa, as.a.name);
                if (as.a.index) |ix| {
                    try tok.append(sh.sa, '[');
                    try tok.appendSlice(sh.sa, try unparse.word_source(sh, ix));
                    try tok.append(sh.sa, ']');
                }
                if (as.ex.scalar) |v| {
                    try tok.appendSlice(sh.sa, if (as.a.append) "+=" else "=");
                    try tok.appendSlice(sh.sa, v);
                }
                try strutil.quote_xtrace_u(sh.sa, &w, tok.items, sh.utf8);
            },
        }
    }
    try w.append(sh.sa, '\n');
    const name = if (items.len > 0) switch (items[0]) {
        .arg => |a| a,
        else => "",
    } else "";
    if (std.mem.eql(u8, name, "export") or std.mem.eql(u8, name, "readonly")) {
        for (items) |it| {
            switch (it) {
                .assign => |as| if (as.ex.scalar) |v| {
                    try ps4(sh, &w);
                    try w.appendSlice(sh.sa, as.a.name);
                    try w.appendSlice(sh.sa, if (as.a.append) "+=" else "=");
                    if (v.len > 0) try strutil.quote_xtrace_u(sh.sa, &w, v, sh.utf8);
                    try w.append(sh.sa, '\n');
                },
                else => {},
            }
        }
    }
    _ = sys.write_all(2, w.items);
}

fn xtrace_simple(sh: *Shell, s: ast.Simple, argv: []const []const u8, assign_vals: []const []const u8) Err!void {
    var w: std.ArrayList(u8) = .empty;
    try ps4(sh, &w);
    var first = true;
    for (s.assigns, 0..) |as, i| {
        if (!first) try w.append(sh.sa, ' ');
        first = false;
        try w.appendSlice(sh.sa, as.name);
        if (as.index != null) try w.appendSlice(sh.sa, "[..]");
        try w.appendSlice(sh.sa, if (as.append) "+=" else "=");
        if (i < assign_vals.len and assign_vals[i].len > 0) try strutil.quote_xtrace_u(sh.sa, &w, assign_vals[i], sh.utf8);
    }
    if (s.assigns.len > 0 and argv.len > 0) {
        try w.append(sh.sa, '\n');
        try ps4(sh, &w);
        first = true;
    }
    for (argv) |a| {
        if (!first) try w.append(sh.sa, ' ');
        first = false;
        try strutil.quote_xtrace_u(sh.sa, &w, a, sh.utf8);
    }
    try w.append(sh.sa, '\n');
    _ = sys.write_all(2, w.items);
}

fn plain_lit(w: ast.Word) ?[]const u8 {
    if (w.parts.len == 1) switch (w.parts[0]) {
        .lit => |t| return t,
        else => {},
    };
    return null;
}

fn alias_text(sh: *Shell, c: *const ast.Command, s: ast.Simple) Err!?[]const u8 {
    for (c.redirs) |r| switch (r.op) {
        .heredoc, .heredoc_strip => return null,
        else => {},
    };
    const first = plain_lit(s.words[0]) orelse return null;
    var value = sh.aliases.get(first) orelse return null;
    if (sh.alias_lines.get(first)) |dl| {
        if (c.line <= dl) return null;
    }
    var w: unparse.W = .{ .sh = sh, .a = sh.sa };
    if (s.assigns.len > 0) {
        try w.simple(.{ .assigns = s.assigns, .words = &.{} });
        try w.put(" ");
    }
    try w.put(value);
    var wi: usize = 1;
    while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t') and wi < s.words.len) {
        const nxt = plain_lit(s.words[wi]) orelse break;
        const v2 = sh.aliases.get(nxt) orelse break;
        if (sh.alias_lines.get(nxt)) |dl| {
            if (c.line <= dl) break;
        }
        try w.put(v2);
        value = v2;
        wi += 1;
    }
    while (wi < s.words.len) : (wi += 1) {
        try w.put(" ");
        try w.word(s.words[wi]);
    }
    for (c.redirs) |r| {
        try w.put(" ");
        try w.redir(r);
    }
    return w.out.items;
}

fn is_decl_name(name: []const u8) bool {
    return std.mem.eql(u8, name, "declare") or std.mem.eql(u8, name, "typeset") or std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "export") or std.mem.eql(u8, name, "readonly");
}

fn assign_split(w: ast.Word) ?struct { name: []const u8, idx: ?[]const u8, append: bool, rest: ast.Word, rest_parts_start: usize, first_tail: []const u8 } {
    if (w.parts.len == 0) return null;
    const first = switch (w.parts[0]) {
        .lit => |t| t,
        else => return null,
    };
    var i: usize = 0;
    if (first.len == 0 or !(std.ascii.isAlphabetic(first[0]) or first[0] == '_')) return null;
    while (i < first.len and (std.ascii.isAlphanumeric(first[i]) or first[i] == '_')) i += 1;
    const name = first[0..i];
    var idx: ?[]const u8 = null;
    if (i < first.len and first[i] == '[') {
        const close = std.mem.findScalarPos(u8, first, i, ']') orelse return null;
        idx = first[i + 1 .. close];
        i = close + 1;
    }
    var append = false;
    if (i < first.len and first[i] == '+') {
        append = true;
        i += 1;
    }
    if (i >= first.len or first[i] != '=') return null;
    i += 1;
    return .{ .name = name, .idx = idx, .append = append, .rest = .{ .parts = w.parts[1..], .line = w.line }, .rest_parts_start = 1, .first_tail = first[i..] };
}

fn make_decl_assign(sh: *Shell, w: ast.Word) Err!?ast.Assign {
    const sp = assign_split(w) orelse return null;
    var parts_list: std.ArrayList(ast.Part) = .empty;
    if (sp.first_tail.len > 0) try parts_list.append(sh.sa, .{ .lit = sp.first_tail });
    try parts_list.appendSlice(sh.sa, sp.rest.parts);
    var value: ast.AssignValue = .{ .scalar = .{ .parts = parts_list.items, .line = w.line } };
    if (parts_list.items.len == 1 and parts_list.items[0] == .array_init) {
        value = .{ .array = parts_list.items[0].array_init };
    }
    var idx_word: ?ast.Word = null;
    if (sp.idx) |ix| {
        const parts = try sh.sa.alloc(ast.Part, 1);
        parts[0] = .{ .lit = ix };
        idx_word = .{ .parts = parts, .line = w.line };
    }
    return .{ .name = sp.name, .index = idx_word, .append = sp.append, .value = value };
}

fn trace_assign(sh: *Shell, a: ast.Assign, val: []const u8) Err!void {
    var w: std.ArrayList(u8) = .empty;
    try ps4(sh, &w);
    try w.appendSlice(sh.sa, a.name);
    if (a.index) |ix| {
        try w.append(sh.sa, '[');
        try w.appendSlice(sh.sa, try unparse.word_source(sh, ix));
        try w.append(sh.sa, ']');
    }
    try w.appendSlice(sh.sa, if (a.append) "+=" else "=");
    if (val.len > 0) try strutil.quote_xtrace_u(sh.sa, &w, val, sh.utf8);
    try w.append(sh.sa, '\n');
    _ = sys.write_all(2, w.items);
}

fn trace_array_source(sh: *Shell, a: ast.Assign, elems: []const ast.ArrayElem) Err!void {
    var wr: unparse.W = .{ .sh = sh, .a = sh.sa };
    try ps4(sh, &wr.out);
    try wr.put(a.name);
    try wr.put(if (a.append) "+=" else "=");
    try wr.part(.{ .array_init = elems });
    try wr.put("\n");
    _ = sys.write_all(2, wr.out.items);
}

pub fn trace_pairs(sh: *Shell, w: *std.ArrayList(u8), name: []const u8, append: bool, pairs: []const Pair, assoc: bool) Err!void {
    try w.appendSlice(sh.sa, name);
    try w.appendSlice(sh.sa, if (append) "+=(" else "=(");
    for (pairs, 0..) |p, i| {
        if (i > 0) try w.append(sh.sa, ' ');
        if (p.key) |k| {
            try w.append(sh.sa, '[');
            if (assoc) {
                try w.append(sh.sa, '\'');
                try w.appendSlice(sh.sa, k);
                try w.append(sh.sa, '\'');
            } else try w.appendSlice(sh.sa, k);
            try w.appendSlice(sh.sa, "]=");
        }
        try w.append(sh.sa, '\'');
        for (p.val) |c| {
            if (c == '\'') try w.appendSlice(sh.sa, "'\\''") else try w.append(sh.sa, c);
        }
        try w.append(sh.sa, '\'');
    }
    try w.append(sh.sa, ')');
}

pub fn expand_assign(sh: *Shell, a: ast.Assign) Err!Expanded {
    switch (a.value) {
        .scalar => |w| {
            const val = try expand.word_string(sh, w);
            var ex: Expanded = .{ .scalar = val };
            if (a.index) |ix| {
                const v = sh.find(a.name);
                if (v != null and v.?.value == .assoc) {
                    ex.sub_key = try expand.word_string(sh, ix);
                } else ex.sub_idx = try expand.index_value(sh, ix);
            }
            return ex;
        },
        .array => |elems| {
            var pairs: std.ArrayList(Pair) = .empty;
            for (elems) |e| {
                if (e.key) |k| {
                    const val = try expand.word_string(sh, e.value);
                    try pairs.append(sh.sa, .{ .key = try expand.word_string(sh, k), .val = val });
                } else {
                    var fields: std.ArrayList([]const u8) = .empty;
                    try expand.word_fields(sh, e.value, &fields);
                    for (fields.items) |f| try pairs.append(sh.sa, .{ .key = null, .idx = null, .val = f });
                }
            }
            return .{ .pairs = pairs.items };
        },
    }
}

pub fn apply_assign(sh: *Shell, a: ast.Assign, ex: Expanded) Err!void {
    if (ex.scalar) |val| {
        if (a.index != null) {
            const v = sh.find(a.name) orelse try sh.new_var(a.name);
            if (v.flags.readonly) return sh.readonly_err(v.name);
            if (v.value == .assoc) {
                const key = ex.sub_key orelse try expand.word_string(sh, a.index.?);
                return sh.assign_assoc(v, key, val, a.append);
            }
            const idx = ex.sub_idx orelse try expand.index_value(sh, a.index.?);
            return sh.assign_indexed(v, idx, val, a.append);
        }
        return sh.assign_scalar(a.name, val, a.append);
    }
    return apply_pairs(sh, a.name, ex.pairs orelse &.{}, a.append);
}

pub fn do_assign(sh: *Shell, a: ast.Assign) Err!void {
    if (sh.opt(.xtrace)) {
        switch (a.value) {
            .array => |elems| try trace_array_source(sh, a, elems),
            else => {},
        }
    }
    const ex = try expand_assign(sh, a);
    if (sh.opt(.xtrace)) {
        switch (a.value) {
            .scalar => try trace_assign(sh, a, ex.scalar.?),
            else => {},
        }
    }
    return apply_assign(sh, a, ex);
}

pub fn apply_pairs(sh: *Shell, name: []const u8, pairs: []const Pair, append: bool) Err!void {
    const v = sh.find(name) orelse try sh.new_var(name);
    if (v.flags.readonly) return sh.readonly_err(v.name);
    v.array_set = true;
    if (v.value == .assoc) {
        if (!append) sh.clear_array(v);
        var pending_key: ?[]const u8 = null;
        for (pairs) |p| {
            if (p.key) |k| {
                try sh.assign_assoc(v, k, p.val, false);
            } else if (pending_key) |k| {
                try sh.assign_assoc(v, k, p.val, false);
                pending_key = null;
            } else pending_key = p.val;
        }
        if (pending_key) |k| try sh.assign_assoc(v, k, "", false);
        return;
    }
    try sh.declare_indexed(v);
    if (!append) sh.clear_array(v);
    var next: i64 = v.value.indexed.max_index() + 1;
    for (pairs) |p| {
        if (p.key) |k| next = try sh.eval_int(k);
        try sh.assign_indexed(v, next, p.val, false);
        next += 1;
    }
}

pub fn mark_final_list(sh: *Shell, l: ast.List) void {
    if (l.items.len == 0) return;
    const it = l.items[l.items.len - 1];
    if (it.background) return;
    mark_final_ao(sh, it.and_or);
}

pub fn mark_final_ao(sh: *Shell, ao: ast.AndOr) void {
    if (ao.rest.len != 0) return;
    const p = ao.first;
    if (p.negate or p.time != .none or p.commands.len != 1) return;
    if (p.commands[0].body != .simple) return;
    if (sh.trap_exit.kind == .cmd and !sh.trap_exit.inherited) return;
    sh.exec_final_cmd = &p.commands[0];
}

fn run_simple(sh: *Shell, c: *const ast.Command, s: ast.Simple, final_in: bool) Err!u8 {
    var final = final_in;
    if (sh.exec_final_cmd == c) {
        sh.exec_final_cmd = null;
        if (!(sh.trap_exit.kind == .cmd and !sh.trap_exit.inherited)) final = true;
    }
    sh.lineno = c.line;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    sh.cmdsub_status = null;
    if (sh.alias_depth < 16 and s.words.len > 0 and sh.aliases.count() > 0 and sh.shopt(.expand_aliases)) {
        if (try alias_text(sh, c, s)) |txt| {
            sh.alias_depth += 1;
            defer sh.alias_depth -= 1;
            const was_v = sh.opt(.verbose);
            sh.set_opt(.verbose, false);
            defer sh.set_opt(.verbose, was_v);
            return run_string(sh, txt, .{ .label = "", .line_base = c.line -| 1 });
        }
    }
    if (sh.in_trap == 0 and !sh.in_debug_trap and !sh.in_err_trap) sh.cur_cmd = c;
    var argv: std.ArrayList([]const u8) = .empty;
    var decl: std.ArrayList(DeclItem) = .empty;
    var decl_mode = false;
    if (s.words.len > 0) {
        for (s.words, 0..) |w, wi| {
            if (decl_mode) {
                if (try make_decl_assign(sh, w)) |as| {
                    const ex = try expand_assign(sh, as);
                    try decl.append(sh.sa, .{ .assign = .{ .a = as, .ex = ex } });
                    continue;
                }
                const before = argv.items.len;
                try expand.word_fields(sh, w, &argv);
                for (argv.items[before..]) |f| try decl.append(sh.sa, .{ .arg = f });
                continue;
            }
            try expand.word_fields(sh, w, &argv);
            if (wi == 0 and argv.items.len > 0 and is_decl_name(argv.items[0]) and sh.funcs.get(argv.items[0]) == null) {
                decl_mode = true;
                try decl.append(sh.sa, .{ .arg = argv.items[0] });
            }
        }
    }
    if (sh.trap_debug.kind == .cmd and !sh.trap_debug.inherited and !sh.in_debug_trap) try run_debug_trap(sh, c);

    if (argv.items.len == 0) {
        var scope: redir.Scope = .{};
        defer scope.restore(sh);
        for (s.assigns) |a| try do_assign(sh, a);
        if (c.redirs.len > 0) {
            if (!try redir.apply(sh, c.redirs, &scope)) return 1;
        }
        set_last_arg(sh, "");
        const st: u8 = sh.cmdsub_status orelse 0;
        sh.status = st;
        if (s.assigns.len > 0 or true) {
            if (st != 0) try errexit_check(sh, st);
        }
        return st;
    }

    const temp_base = sh.temps.items.len;
    defer sh.pop_temps(temp_base);
    var avals: std.ArrayList([]const u8) = .empty;
    for (s.assigns) |a| {
        switch (a.value) {
            .scalar => |w| {
                const val = try expand.word_string(sh, w);
                try avals.append(sh.sa, val);
                if (a.index != null) continue;
                sh.push_temp(a.name, val) catch |e| switch (e) {
                    error.Abort => {},
                    else => return e,
                };
            },
            .array => {},
        }
    }
    if (sh.opt(.xtrace)) {
        if (decl_mode) try xtrace_decl(sh, s, decl.items, avals.items) else try xtrace_simple(sh, s, argv.items, avals.items);
    }
    sh.cur_command = argv.items;
    const st = try dispatch(sh, argv.items, decl.items, decl_mode, c.redirs, final);
    if (decl_mode and decl.items.len > 0) {
        switch (decl.items[decl.items.len - 1]) {
            .arg => |a| set_last_arg(sh, a),
            .assign => |as| {
                var tok: std.ArrayList(u8) = .empty;
                try tok.appendSlice(sh.sa, as.a.name);
                if (as.ex.scalar) |v| {
                    try tok.appendSlice(sh.sa, if (as.a.append) "+=" else "=");
                    try tok.appendSlice(sh.sa, v);
                }
                set_last_arg(sh, tok.items);
            },
        }
    } else if (argv.items.len > 0) set_last_arg(sh, argv.items[argv.items.len - 1]);
    sh.status = st;
    for (sh.procsub_fds.items) |fd| _ = sys.close(fd);
    sh.procsub_fds.clearRetainingCapacity();
    return st;
}

pub const Dispatch = struct {
    skip_funcs: bool = false,
    builtin_only: bool = false,
};

pub fn dispatch(sh: *Shell, argv: []const []const u8, decl: []const DeclItem, decl_mode: bool, redirs: []const ast.Redirect, final: bool) Err!u8 {
    return dispatch_ex(sh, argv, decl, decl_mode, redirs, final, .{});
}

pub fn dispatch_ex(sh: *Shell, argv: []const []const u8, decl: []const DeclItem, decl_mode: bool, redirs: []const ast.Redirect, final: bool, d: Dispatch) Err!u8 {
    const name = argv[0];
    if (!d.skip_funcs and !d.builtin_only) {
        if (sh.pending_funcs.count() > 0 and !sh.funcs.contains(name)) try import_function(sh, name);
        if (sh.funcs.get(name)) |f| {
            var scope: redir.Scope = .{};
            defer scope.restore(sh);
            if (redirs.len > 0 and !try redir.apply(sh, redirs, &scope)) return 1;
            return call_function(sh, f, argv[1..]);
        }
    }
    if (builtins.lookup(name)) |b| {
        var scope: redir.Scope = .{};
        const is_exec = std.mem.eql(u8, name, "exec");
        defer if (!is_exec) scope.restore(sh);
        if (redirs.len > 0 and !try redir.apply(sh, redirs, if (is_exec) null else &scope)) return 1;
        if (decl_mode and b.decl != null) return b.decl.?(sh, decl);
        return b.run(sh, argv);
    }
    if (d.builtin_only) {
        sh.bmsg("builtin", "{s}: not a shell builtin", .{name});
        return 1;
    }
    if (registry.supports(argv) and util_ok(sh, name)) {
        return run_util(sh, argv, redirs);
    }
    return run_external(sh, argv, redirs, final);
}

fn util_ok(sh: *Shell, name: []const u8) bool {
    _ = sh;
    if (std.mem.eql(u8, name, "head")) {
        if (sys.lseek(0, 0, 1) >= 0) return false;
    }
    return true;
}

fn import_function(sh: *Shell, name: []const u8) Err!void {
    const kv = sh.pending_funcs.fetchRemove(name) orelse return;
    const text = try std.mem.concat(sh.sa, u8, &.{ name, " ", kv.value });
    sh.gpa.free(kv.key);
    sh.gpa.free(kv.value);
    _ = try run_string(sh, text, .{ .label = "", .line_base = 0 });
}

pub fn call_function(sh: *Shell, f: *const shell.Func, args: []const []const u8) Err!u8 {
    if (sh.frames.items.len >= 2000) {
        sh.msg("{s}: maximum function nesting level exceeded (2000)", .{f.name});
        sh.status = 1;
        return error.Abort;
    }
    var saved_pos = sh.pos;
    sh.pos = .empty;
    errdefer {
        for (sh.pos.items) |p| sh.gpa.free(p);
        sh.pos.deinit(sh.gpa);
        sh.pos = saved_pos;
    }
    try sh.set_pos(args);
    try sh.frames.append(sh.gpa, .{
        .func = f,
        .call_line = sh.lineno,
        .call_file = sh.cur_file,
        .saved_pos = .empty,
        .saved_file = sh.cur_file,
    });
    const saved_file = sh.cur_file;
    const saved_line = sh.lineno;
    sh.cur_file = f.file;
    const saved_loop = sh.loop_depth;
    sh.loop_depth = 0;
    const saved_trap_debug = sh.trap_debug;
    const saved_trap_err = sh.trap_err;
    const saved_trap_return = sh.trap_return;
    if (!sh.opt(.functrace)) {
        sh.trap_debug = .{};
        sh.trap_return = .{};
    }
    if (!sh.opt(.errtrace)) sh.trap_err = .{};
    var status: u8 = 0;
    var ret_err: ?Err = null;
    status = run_command(sh, f.body, false) catch |e| blk: {
        switch (e) {
            error.Return => break :blk sh.status,
            else => {
                ret_err = e;
                break :blk sh.status;
            },
        }
    };
    sh.loop_depth = saved_loop;
    if (ret_err == null and sh.trap_return.kind == .cmd and !sh.trap_return.inherited) {
        sh.status = status;
        sh.eval_depth += 1;
        run_trap_text(sh, sh.trap_return.cmd, sh.lineno -| 1) catch |e| {
            ret_err = e;
        };
        sh.eval_depth -= 1;
        status = sh.status;
    }
    if (sh.trap_debug.kind == .none) sh.trap_debug = saved_trap_debug;
    if (sh.trap_err.kind == .none) sh.trap_err = saved_trap_err;
    if (sh.trap_return.kind == .none) sh.trap_return = saved_trap_return;
    var frame = sh.frames.pop().?;
    sh.pop_locals(&frame);
    frame.saved_pos.deinit(sh.gpa);
    for (sh.pos.items) |p| sh.gpa.free(p);
    sh.pos.deinit(sh.gpa);
    sh.pos = saved_pos;
    saved_pos = .empty;
    sh.cur_file = saved_file;
    sh.lineno = saved_line;
    if (ret_err) |e| return e;
    return status;
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

pub const Resolve = union(enum) {
    found: []const u8,
    not_found,
    denied: []const u8,
    is_dir: []const u8,
};

pub fn path_value(sh: *Shell) []const u8 {
    if (sh.vars.get("PATH")) |v| {
        if (sh.scalar_of(v)) |s| return s;
        if (v.value != .none) return "";
    }
    return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
}

pub fn resolve(sh: *Shell, name: []const u8, use_hash: bool) Err!Resolve {
    if (std.mem.findScalar(u8, name, '/') != null) {
        const st = sys.stat_path(name, true) orelse return .not_found;
        if (st.is_dir()) return .{ .is_dir = name };
        if (!sys.path_exec_ok(name)) return .{ .denied = name };
        return .{ .found = name };
    }
    const pv = path_value(sh);
    if (use_hash) {
        if (sh.hash_path.len != pv.len or !std.mem.eql(u8, sh.hash_path, pv)) {
            flush_hash(sh);
            sh.hash_path = sh.gpa.dupe(u8, pv) catch "";
        }
        if (sh.cmd_hash.getPtr(name)) |e| {
            if (sys.path_exec_ok(e.path)) {
                e.hits += 1;
                return .{ .found = e.path };
            }
        }
    }
    var denied: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, pv, ':');
    while (it.next()) |dir| {
        const d = if (dir.len == 0) "." else dir;
        const full = try std.mem.concat(sh.sa, u8, &.{ d, "/", name });
        const st = sys.stat_path(full, true) orelse continue;
        if (st.is_dir()) continue;
        if (!sys.path_exec_ok(full)) {
            if (denied == null) denied = full;
            continue;
        }
        if (use_hash) {
            const k = try sh.gpa.dupe(u8, name);
            const pth = try sh.gpa.dupe(u8, full);
            if (try sh.cmd_hash.fetchPut(sh.gpa, k, .{ .path = pth, .hits = 1 })) |old| {
                sh.gpa.free(old.key);
                sh.gpa.free(old.value.path);
            }
            return .{ .found = pth };
        }
        return .{ .found = full };
    }
    if (denied) |dn| return .{ .denied = dn };
    return .not_found;
}

pub fn flush_hash(sh: *Shell) void {
    var it = sh.cmd_hash.iterator();
    while (it.next()) |e| {
        sh.gpa.free(e.key_ptr.*);
        sh.gpa.free(e.value_ptr.path);
    }
    sh.cmd_hash.clearRetainingCapacity();
    if (sh.hash_path.len > 0) sh.gpa.free(sh.hash_path);
    sh.hash_path = &.{};
}

fn run_external(sh: *Shell, argv: []const []const u8, redirs: []const ast.Redirect, final: bool) Err!u8 {
    const name = argv[0];
    const r = try resolve(sh, name, true);
    switch (r) {
        .found => |path| return spawn(sh, path, argv, redirs, final),
        else => {
            var scope: redir.Scope = .{};
            defer scope.restore(sh);
            if (redirs.len > 0 and !try redir.apply(sh, redirs, &scope)) return 1;
            switch (r) {
                .not_found => {
                    if (std.mem.findScalar(u8, name, '/') != null) {
                        sh.msg("{s}: No such file or directory", .{name});
                    } else sh.msg("{s}: command not found", .{name});
                    return 127;
                },
                .denied => |p| {
                    sh.msg("{s}: Permission denied", .{p});
                    return 126;
                },
                .is_dir => |p| {
                    sh.msg("{s}: Is a directory", .{p});
                    return 126;
                },
                .found => unreachable,
            }
        },
    }
}

pub fn exec_failed(sh: *Shell, path: []const u8, argv: []const []const u8) u8 {
    const e = sys.errno();
    if (e == sys.ENOEXEC) {
        const st = run_as_script(sh, path, argv) catch 126;
        return st;
    }
    if (e == sys.ENOENT) {
        if (shebang_interp(sh, path)) |interp| {
            sh.msg_raw("{s}: {s}: {s}: bad interpreter: No such file or directory\n", .{ sh.script_name, path, interp });
            return 126;
        }
        sh.msg("{s}: {s}", .{ path, "cannot execute: required file not found" });
        return 126;
    }
    sh.msg("{s}: {s}", .{ path, sys.msg_for(e) });
    return if (e == sys.ENOENT) 127 else 126;
}

fn shebang_interp(sh: *Shell, path: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const z = sys.cstr(&buf, path) orelse return null;
    const fd = sys.open(z, sys.O.RDONLY);
    if (fd < 0) return null;
    defer _ = sys.close(fd);
    var head: [256]u8 = undefined;
    const n = sys.read_some(fd, &head);
    if (n < 3 or head[0] != '#' or head[1] != '!') return null;
    const line = head[2..@intCast(n)];
    var end: usize = 0;
    while (end < line.len and line[end] != '\n' and line[end] != ' ' and line[end] != '\t') end += 1;
    const interp = std.mem.trim(u8, line[0..end], " \t");
    if (interp.len == 0) return null;
    return sh.sa.dupe(u8, interp) catch null;
}

fn run_as_script(sh: *Shell, path: []const u8, argv: []const []const u8) Err!u8 {
    var buf: [4096]u8 = undefined;
    const z = sys.cstr(&buf, path) orelse return 126;
    const fd = sys.open(z, sys.O.RDONLY);
    if (fd < 0) return 126;
    var head: [128]u8 = undefined;
    const n = sys.read_some(fd, &head);
    _ = sys.close(fd);
    if (n > 0 and std.mem.indexOfScalar(u8, head[0..@intCast(n)], 0) != null) {
        sh.msg("{s}: cannot execute binary file: Exec format error", .{path});
        return 126;
    }
    const a = sh.sa;
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "zash");
    try args.append(a, path);
    for (argv[1..]) |x| try args.append(a, x);
    const argz = try make_argv_z(sh, args.items);
    const env = try sh.env_block_get();
    _ = sys.execve("/proc/self/exe", argz, @ptrCast(env.ptrs.items.ptr));
    sh.msg("{s}: cannot execute: {s}", .{ path, sys.msg_for(sys.errno()) });
    return 126;
}

fn spawn(sh: *Shell, path: []const u8, argv: []const []const u8, redirs: []const ast.Redirect, final: bool) Err!u8 {
    var pbuf: [4096]u8 = undefined;
    const pz = sys.cstr(&pbuf, path) orelse {
        sh.msg("{s}: File name too long", .{path});
        return 126;
    };
    const argz = try make_argv_z(sh, argv);
    const env = try sh.env_block_get();
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env.ptrs.items.ptr);
    if (!final) {
        const pid = sys.fork();
        if (pid < 0) {
            sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
            return 1;
        }
        if (pid == 0) {
            child_prepare_exec(sh);
            if (redirs.len > 0 and !(redir.apply(sh, redirs, null) catch false)) sys._exit(1);
            _ = sys.execve(pz, argz, envp);
            const st = exec_failed(sh, path, argv);
            sys._exit(st);
        }
        return wait_report(sh, pid);
    }
    if (redirs.len > 0 and !try redir.apply(sh, redirs, null)) return 1;
    child_prepare_exec(sh);
    _ = sys.execve(pz, argz, envp);
    const st = exec_failed(sh, path, argv);
    return st;
}

pub fn child_prepare_exec(sh: *Shell) void {
    var i: usize = 1;
    while (i < shell.nsig) : (i += 1) {
        if (sh.traps[i].kind == .cmd) sys.set_signal(@intCast(i), sys.SIG_DFL);
    }
    var set: sys.SigSet = .{};
    _ = sys.sigemptyset(&set);
    _ = sys.sigprocmask(2, &set, null);
}

fn run_util(sh: *Shell, argv: []const []const u8, redirs: []const ast.Redirect) Err!u8 {
    const run_fn = registry.lookup(argv[0]) orelse return run_external(sh, argv, redirs, false);
    var scope: redir.Scope = .{};
    defer scope.restore(sh);
    if (redirs.len > 0 and !try redir.apply(sh, redirs, &scope)) return 1;
    const old_pipe = sys.get_signal(sys.SIGPIPE);
    if (!sh.in_subshell) sys.set_signal(sys.SIGPIPE, sys.SIG_IGN);
    defer if (!sh.in_subshell) sys.set_signal(sys.SIGPIPE, old_pipe);
    var in_buf: [65536]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    const in_f: std.Io.File = .{ .handle = 0, .flags = .{ .nonblocking = false } };
    const out_f: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
    const err_f: std.Io.File = .{ .handle = 2, .flags = .{ .nonblocking = false } };
    var in_r = in_f.readerStreaming(sh.io, &in_buf);
    var out_w = out_f.writerStreaming(sh.io, &out_buf);
    var err_w = err_f.writerStreaming(sh.io, &err_buf);
    const EnvCtx = struct {
        sh: *Shell,
        fn get(c: ?*const anyopaque, key: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(c.?));
            return self.sh.get_scalar(key);
        }
    };
    var ectx: EnvCtx = .{ .sh = sh };
    const env: common.EnvView = .{ .context = &ectx, .get_fn = EnvCtx.get };
    const cwd = sh.get_scalar("PWD") orelse ".";
    var ctx: common.Ctx = .{ .alloc = sh.gpa, .io = sh.io, .cwd = cwd, .env = &env };
    const st = run_fn(&ctx, argv, .{ .in = &in_r.interface, .out = &out_w.interface, .err = &err_w.interface });
    out_w.interface.flush() catch {};
    err_w.interface.flush() catch {};
    return st;
}

pub fn run_background(sh: *Shell, item: ast.Item) Err!u8 {
    const pid = sys.fork();
    if (pid < 0) {
        sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
        return 1;
    }
    if (pid == 0) {
        enter_child(sh);
        if (!sh.opt(.monitor)) {
            sys.set_signal(2, sys.SIG_IGN);
            sys.set_signal(3, sys.SIG_IGN);
            if (!has_stdin_redir(item)) {
                const fd = sys.open("/dev/null", sys.O.RDONLY);
                if (fd >= 0) {
                    _ = sys.dup2(fd, 0);
                    _ = sys.close(fd);
                }
            }
        }
        mark_final_ao(sh, item.and_or);
        const st = run_and_or(sh, item.and_or) catch |e| switch (e) {
            error.OutOfMemory => 1,
            else => sh.status,
        };
        child_exit(sh, st);
    }
    sh.last_bg = pid;
    const text = unparse.list_source(sh, .{ .items = &[_]ast.Item{.{ .and_or = item.and_or, .background = false, .line = item.line }} }) catch "";
    try sh.add_job(pid, text);
    sh.status = 0;
    return 0;
}

fn has_stdin_redir(item: ast.Item) bool {
    const cmds = item.and_or.first.commands;
    if (cmds.len == 0) return false;
    for (cmds[0].redirs) |r| {
        switch (r.op) {
            .in, .here_str, .heredoc, .heredoc_strip, .read_write, .dup_in => if (r.fd == .none or (r.fd == .num and r.fd.num == 0)) return true,
            else => {},
        }
    }
    return false;
}

pub fn cmd_subst(sh: *Shell, cs: *const ast.CmdSubst) Err![]const u8 {
    const a = sh.sa;
    if (cs.body.items.len == 1) {
        const it = cs.body.items[0];
        if (!it.background and it.and_or.rest.len == 0 and it.and_or.first.commands.len == 1 and !it.and_or.first.negate) {
            const cmd = it.and_or.first.commands[0];
            if (cmd.body == .simple and cmd.body.simple.words.len == 0 and cmd.body.simple.assigns.len == 0 and cmd.redirs.len == 1 and cmd.redirs[0].op == .in and cmd.redirs[0].fd == .none) {
                const path = try expand.word_string(sh, cmd.redirs[0].target);
                if (read_whole_file(sh, path)) |txt| {
                    sh.cmdsub_status = 0;
                    return strip_nl(txt);
                } else {
                    sh.msg("{s}: {s}", .{ path, sys.msg_for(sys.errno()) });
                    sh.cmdsub_status = 1;
                    return "";
                }
            }
        }
    }
    var fds: [2]c_int = undefined;
    if (sys.pipe(&fds) != 0) {
        sh.msg("cannot make pipe for command substitution: {s}", .{sys.msg_for(sys.errno())});
        return error.Abort;
    }
    const pid = sys.fork();
    if (pid < 0) {
        _ = sys.close(fds[0]);
        _ = sys.close(fds[1]);
        sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
        return error.Abort;
    }
    if (pid == 0) {
        _ = sys.close(fds[0]);
        _ = sys.dup2(fds[1], 1);
        _ = sys.close(fds[1]);
        enter_child(sh);
        sh.cmdsub_depth += 1;
        if (!sh.shopt(.inherit_errexit)) sh.set_opt(.errexit, false);
        mark_final_list(sh, cs.body);
        const st = run_list(sh, cs.body) catch |e| switch (e) {
            error.OutOfMemory => 1,
            else => sh.status,
        };
        child_exit(sh, st);
    }
    _ = sys.close(fds[1]);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = sys.read_some(fds[0], &chunk);
        if (n <= 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    _ = sys.close(fds[0]);
    sh.cmdsub_status = wait_pid(sh, pid);
    return strip_nl(buf.items);
}

fn strip_nl(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and s[n - 1] == '\n') n -= 1;
    return s[0..n];
}

pub fn read_whole_file(sh: *Shell, path: []const u8) ?[]const u8 {
    var pb: [4096]u8 = undefined;
    const z = sys.cstr(&pb, path) orelse return null;
    const fd = sys.open(z, sys.O.RDONLY | sys.O.CLOEXEC);
    if (fd < 0) return null;
    defer _ = sys.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = sys.read_some(fd, &chunk);
        if (n < 0) return null;
        if (n == 0) break;
        buf.appendSlice(sh.sa, chunk[0..@intCast(n)]) catch return null;
    }
    return buf.items;
}

fn high_fd(src: c_int) c_int {
    var target: c_int = 63;
    while (target >= 10) : (target -= 1) {
        if (sys.fcntl(target, sys.F_GETFD) < 0) {
            if (sys.dup2(src, target) == target) {
                _ = sys.close(src);
                return target;
            }
        }
    }
    return src;
}

pub fn proc_subst(sh: *Shell, ps: *const ast.ProcSubst) Err![]const u8 {
    var fds: [2]c_int = undefined;
    if (sys.pipe(&fds) != 0) return error.Abort;
    const pid = sys.fork();
    if (pid < 0) {
        _ = sys.close(fds[0]);
        _ = sys.close(fds[1]);
        return error.Abort;
    }
    const mine: usize = if (ps.input) 0 else 1;
    const theirs: usize = 1 - mine;
    if (pid == 0) {
        _ = sys.close(fds[mine]);
        _ = sys.dup2(fds[theirs], if (ps.input) 1 else 0);
        _ = sys.close(fds[theirs]);
        enter_child(sh);
        sh.cmdsub_depth += 1;
        mark_final_list(sh, ps.body);
        const st = run_list(sh, ps.body) catch |e| switch (e) {
            error.OutOfMemory => 1,
            else => sh.status,
        };
        child_exit(sh, st);
    }
    _ = sys.close(fds[theirs]);
    const hi = high_fd(fds[mine]);
    try sh.procsub_fds.append(sh.gpa, hi);
    try sh.add_job(pid, "procsub");
    sh.jobs.items[sh.jobs.items.len - 1].disowned = true;
    return sh.tmp_fmt("/dev/fd/{d}", .{hi});
}

pub fn check_signals(sh: *Shell) Err!void {
    const bits = shell.pending_signals.swap(0, .seq_cst);
    if (bits == 0) return;
    var sig: u6 = 1;
    while (sig < 63) : (sig += 1) {
        if ((bits >> sig) & 1 == 0) continue;
        const t = sh.traps[sig];
        if (t.kind == .cmd and !t.inherited) {
            const saved = sh.status;
            sh.in_trap += 1;
            defer sh.in_trap -= 1;
            sh.eval_depth += 1;
            defer sh.eval_depth -= 1;
            try run_trap_text(sh, t.cmd, 0);
            sh.status = saved;
        }
    }
}

fn run_debug_trap(sh: *Shell, c: *const ast.Command) Err!void {
    sh.in_debug_trap = true;
    defer sh.in_debug_trap = false;
    const saved = sh.status;
    const m = sh.scratch.mark();
    defer sh.scratch.release(m);
    const text = try unparse.command_source(sh, c);
    sh.bash_command = text;
    sh.eval_depth += 1;
    defer sh.eval_depth -= 1;
    try run_trap_text(sh, sh.trap_debug.cmd, c.line -| 1);
    sh.status = saved;
}

pub fn run_trap_text(sh: *Shell, text: []const u8, line_base: u32) Err!void {
    const saved_file = sh.cur_file;
    const saved_line = sh.lineno;
    defer {
        sh.cur_file = saved_file;
        sh.lineno = saved_line;
    }
    const st = sh.status;
    _ = run_string(sh, text, .{ .label = "", .line_base = line_base }) catch |e| switch (e) {
        error.Break, error.Continue => {},
        else => return e,
    };
    sh.status = st;
}

pub const StringOpts = struct {
    label: []const u8 = "",
    line_base: u32 = 0,
    keep_status: bool = false,
};

pub fn run_string(sh: *Shell, src: []const u8, o: StringOpts) Err!u8 {
    var arena = try sh.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(sh.gpa);
    const gen = sh.func_gen;
    defer {
        if (sh.func_gen == gen) {
            arena.deinit();
            sh.gpa.destroy(arena);
        } else {
            sh.keep_arenas.append(sh.gpa, arena) catch {};
        }
    }
    const src_copy = try arena.allocator().dupe(u8, src);
    var p = parser.Parser.init(arena.allocator(), src_copy, .{});
    p.lex.line_base = o.line_base + 1;
    p.lex.cache_line = p.lex.line_base;
    const list = p.parse_script() catch |e| switch (e) {
        error.Syntax => {
            report_parse_error(sh, p.lex.err.?, o.label);
            sh.status = 2;
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const saved_line = sh.lineno;
    defer sh.lineno = saved_line;
    return run_top_inner(sh, list, src_copy, o.line_base);
}

fn run_top_inner(sh: *Shell, list: ast.List, src: []const u8, base: u32) Err!u8 {
    var status: u8 = sh.status;
    var next_line: u32 = 0;
    for (list.items, 0..) |item, idx| {
        if (sh.opt(.verbose)) {
            const m = sh.scratch.mark();
            verbose_echo(sh, src, list, idx, &next_line, base);
            sh.scratch.release(m);
        }
        status = try run_item(sh, item);
        try check_signals(sh);
    }
    return status;
}

pub fn report_parse_error(sh: *Shell, e: lexer.ParseError, label: []const u8) void {
    const file = if (sh.cur_file.len > 0) sh.cur_file else sh.script_name;
    var aw = std.Io.Writer.Allocating.init(sh.sa);
    const prefix = if (label.len > 0) (std.fmt.allocPrint(sh.sa, "{s}: {s}", .{ file, label }) catch file) else file;
    e.write(&aw.writer, prefix) catch {};
    _ = sys.write_all(2, aw.written());
}

pub fn run_source_text(sh: *Shell, src: []const u8, file: []const u8, line_base: u32) Err!u8 {
    _ = file;
    var arena = try sh.gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(sh.gpa);
    const gen = sh.func_gen;
    defer {
        if (sh.func_gen == gen) {
            arena.deinit();
            sh.gpa.destroy(arena);
        } else {
            sh.keep_arenas.append(sh.gpa, arena) catch {};
        }
    }
    const src_copy = try arena.allocator().dupe(u8, src);
    var p = parser.Parser.init(arena.allocator(), src_copy, .{});
    p.lex.line_base = line_base + 1;
    p.lex.cache_line = p.lex.line_base;
    const list = p.parse_script() catch |e| switch (e) {
        error.Syntax => {
            report_parse_error(sh, p.lex.err.?, "");
            sh.status = 2;
            return 2;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return run_top(sh, list, src_copy);
}

const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const vars_mod = @import("vars.zig");
const bump = @import("bump.zig");
const Allocator = std.mem.Allocator;

pub const Var = vars_mod.Var;
pub const Vars = vars_mod.Vars;

pub const Err = error{ OutOfMemory, Abort, Exit, Break, Continue, Return, ArithError };

pub const Opt = enum {
    allexport,
    braceexpand,
    emacs,
    errexit,
    errtrace,
    functrace,
    hashall,
    histexpand,
    history,
    ignoreeof,
    interactive_comments,
    keyword,
    monitor,
    noclobber,
    noexec,
    noglob,
    nolog,
    notify,
    nounset,
    onecmd,
    physical,
    pipefail,
    posix,
    privileged,
    verbose,
    vi,
    xtrace,
};

pub const opt_names = [_][]const u8{
    "allexport", "braceexpand",          "emacs",    "errexit",  "errtrace",  "functrace",  "hashall", "histexpand", "history",
    "ignoreeof", "interactive-comments", "keyword",  "monitor",  "noclobber", "noexec",     "noglob",  "nolog",      "notify",
    "nounset",   "onecmd",               "physical", "pipefail", "posix",     "privileged", "verbose", "vi",         "xtrace",
};

pub const Shopt = enum {
    assoc_expand_once,
    autocd,
    cdable_vars,
    cdspell,
    checkhash,
    checkjobs,
    checkwinsize,
    cmdhist,
    compat31,
    compat32,
    compat40,
    compat41,
    compat42,
    compat43,
    compat44,
    complete_fullquote,
    direxpand,
    dirspell,
    dotglob,
    execfail,
    expand_aliases,
    extdebug,
    extglob,
    extquote,
    failglob,
    force_fignore,
    globasciiranges,
    globstar,
    gnu_errfmt,
    histappend,
    histreedit,
    histverify,
    hostcomplete,
    huponexit,
    inherit_errexit,
    interactive_comments,
    lastpipe,
    lithist,
    localvar_inherit,
    localvar_unset,
    login_shell,
    mailwarn,
    no_empty_cmd_completion,
    nocaseglob,
    nocasematch,
    nullglob,
    progcomp,
    progcomp_alias,
    promptvars,
    restricted_shell,
    shift_verbose,
    sourcepath,
    xpg_echo,
};

pub const Func = struct {
    name: []const u8,
    body: *const ast.Command,
    file: []const u8,
    line: u32,
    exported: bool = false,
    trace: bool = false,
    readonly: bool = false,
};

pub const Saved = struct {
    new: ?*Var,
    old: ?*Var,
};

pub const Frame = struct {
    func: *const Func,
    call_line: u32,
    call_file: []const u8,
    saved_pos: std.ArrayList([]u8),
    saved_argv0_set: bool = false,
    locals: std.ArrayList(Saved) = .empty,
    saved_file: []const u8,
    saved_ret_status: u8 = 0,
    is_source: bool = false,
    loop_depth: u32 = 0,
};

pub const Job = struct {
    pid: i32,
    status: u8 = 0,
    done: bool = false,
    reaped: bool = false,
    notified: bool = false,
    cmd: []const u8 = "",
    id: u32 = 0,
    disowned: bool = false,
};

pub const TrapKind = enum { none, ignore, cmd };

pub const Trap = struct {
    kind: TrapKind = .none,
    cmd: []const u8 = "",
    inherited: bool = false,
};

pub const nsig = 65;

pub const EnvBlock = struct {
    strings: std.ArrayList([:0]u8) = .empty,
    ptrs: std.ArrayList(?[*:0]const u8) = .empty,
};

pub var pending_signals: std.atomic.Value(u64) = .init(0);

pub fn signal_handler(sig: c_int) callconv(.c) void {
    if (sig > 0 and sig < 64) {
        _ = pending_signals.fetchOr(@as(u64, 1) << @intCast(sig), .seq_cst);
    }
}

pub const Shell = struct {
    gpa: Allocator,
    io: std.Io,
    scratch: bump.Bump,
    sa: Allocator,
    vars: Vars = .{},
    funcs: std.StringHashMapUnmanaged(*Func) = .empty,
    aliases: std.StringHashMapUnmanaged([]u8) = .empty,
    cmd_hash: std.StringHashMapUnmanaged(HashEnt) = .empty,
    opts: [opt_names.len]bool = [_]bool{false} ** opt_names.len,
    shopts: [@typeInfo(Shopt).@"enum".fields.len]bool = [_]bool{false} ** @typeInfo(Shopt).@"enum".fields.len,
    status: u8 = 0,
    pos: std.ArrayList([]u8) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    temps: std.ArrayList(Saved) = .empty,
    script_name: []u8 = &.{},
    cur_file: []const u8 = "",
    lineno: u32 = 0,
    pid: i32 = 0,
    ppid: i32 = 0,
    bashpid: i32 = 0,
    last_bg: i32 = 0,
    jobs: std.ArrayList(Job) = .empty,
    next_job_id: u32 = 1,
    traps: [nsig]Trap = [_]Trap{.{}} ** nsig,
    trap_exit: Trap = .{},
    trap_err: Trap = .{},
    trap_debug: Trap = .{},
    trap_return: Trap = .{},
    in_trap: u32 = 0,
    in_debug_trap: bool = false,
    in_subshell: bool = false,
    subshell_level: u32 = 0,
    interactive: bool = false,
    loop_depth: u32 = 0,
    noerrexit: u32 = 0,
    start_ns: i128 = 0,
    seconds_base: i64 = 0,
    rng: std.Random.DefaultPrng,
    dir_stack: std.ArrayList([]u8) = .empty,
    optind_sub: usize = 0,
    keep_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    func_gen: u32 = 0,
    env_gen: u32 = 1,
    env_built_gen: u32 = 0,
    env_block: EnvBlock = .{},
    utf8: bool = false,
    command_text: []const u8 = "",
    pipestatus_pending: bool = false,
    exiting: bool = false,
    in_source_depth: u32 = 0,
    eval_depth: u32 = 0,
    bg_started: bool = false,
    last_arg: []const u8 = &.{},
    source_stack: std.ArrayList([]const u8) = .empty,
    cmdsub_depth: u32 = 0,
    procsub_fds: std.ArrayList(c_int) = .empty,
    hash_hits: u32 = 0,
    trap_signaled: u32 = 0,
    exit_status_pending: ?u8 = null,
    compat_xtrace_fd: c_int = 2,
    errtrace_depth: u32 = 0,
    in_err_trap: bool = false,
    in_cond_depth: u32 = 0,
    parse_arenas_live: u32 = 0,
    coproc_count: u32 = 0,
    lastpipe_ok: bool = false,
    fd_next: c_int = 10,
    sigchld_seen: bool = false,
    alias_gen: u32 = 0,
    getopts_expect: i64 = 1,
    dash_c: bool = false,
    fatal_expand: bool = false,
    ctl_n: u32 = 0,
    cmdsub_status: ?u8 = null,
    cur_command: []const []const u8 = &.{},
    cur_cmd: ?*const ast.Command = null,
    cwd_logical: []u8 = &.{},
    alias_depth: u32 = 0,
    pending_funcs: std.StringHashMapUnmanaged([]u8) = .empty,
    env_funcs_gen: u32 = 0,
    bash_command: []const u8 = "",
    last_arg_buf: []u8 = &.{},
    hash_path: []u8 = &.{},
    pipestatus: [64]u8 = [_]u8{0} ** 64,
    pipestatus_len: usize = 1,
    start_wall_ns: i128 = 0,

    pub const HashEnt = struct { path: []u8, hits: u32 = 0 };

    pub fn init(gpa: Allocator, io: std.Io) Err!*Shell {
        const sh = try gpa.create(Shell);
        sh.* = .{
            .gpa = gpa,
            .io = io,
            .scratch = bump.Bump.init(gpa),
            .sa = undefined,
            .rng = std.Random.DefaultPrng.init(@intCast(sys.now_ns() & 0xffffffff)),
        };
        sh.sa = sh.scratch.allocator();
        sh.start_ns = sys.mono_ns();
        sh.pid = sys.getpid();
        sh.ppid = sys.getppid();
        sh.bashpid = sh.pid;
        sh.opts[@intFromEnum(Opt.braceexpand)] = true;
        sh.opts[@intFromEnum(Opt.hashall)] = true;
        sh.opts[@intFromEnum(Opt.interactive_comments)] = true;
        inline for ([_]Shopt{ .checkwinsize, .cmdhist, .complete_fullquote, .extquote, .force_fignore, .globasciiranges, .hostcomplete, .interactive_comments, .progcomp, .promptvars, .sourcepath, .extglob }) |s| {
            sh.shopts[@intFromEnum(s)] = true;
        }
        return sh;
    }

    pub fn opt(self: *const Shell, o: Opt) bool {
        return self.opts[@intFromEnum(o)];
    }

    pub fn shopt(self: *const Shell, o: Shopt) bool {
        return self.shopts[@intFromEnum(o)];
    }

    pub fn set_opt(self: *Shell, o: Opt, v: bool) void {
        self.opts[@intFromEnum(o)] = v;
    }

    pub fn dup(self: *Shell, s: []const u8) Err![]u8 {
        return self.gpa.dupe(u8, s);
    }

    pub fn tmp_fmt(self: *Shell, comptime fmt: []const u8, args: anytype) Err![]u8 {
        return std.fmt.allocPrint(self.sa, fmt, args) catch return error.OutOfMemory;
    }

    pub fn out(self: *Shell, bytes: []const u8) bool {
        _ = self;
        return sys.write_all(1, bytes);
    }

    pub fn outf(self: *Shell, comptime fmt: []const u8, args: anytype) bool {
        const m = self.scratch.mark();
        defer self.scratch.release(m);
        const s = std.fmt.allocPrint(self.sa, fmt, args) catch return false;
        return sys.write_all(1, s);
    }

    pub fn errraw(self: *Shell, bytes: []const u8) void {
        _ = self;
        _ = sys.write_all(2, bytes);
    }

    pub fn prefix(self: *Shell, w: *std.ArrayList(u8)) void {
        const a = self.sa;
        const file = if (self.cur_file.len > 0) self.cur_file else self.script_name;
        w.appendSlice(a, file) catch return;
        if (self.lineno > 0) {
            w.appendSlice(a, ": line ") catch return;
            w.print(a, "{d}", .{self.lineno}) catch return;
        }
        w.appendSlice(a, ": ") catch return;
    }

    pub fn msg(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        const m = self.scratch.mark();
        defer self.scratch.release(m);
        var w: std.ArrayList(u8) = .empty;
        self.prefix(&w);
        w.print(self.sa, fmt, args) catch return;
        w.append(self.sa, '\n') catch return;
        _ = sys.write_all(2, w.items);
    }

    pub fn bmsg(self: *Shell, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        const m = self.scratch.mark();
        defer self.scratch.release(m);
        var w: std.ArrayList(u8) = .empty;
        self.prefix(&w);
        w.appendSlice(self.sa, name) catch return;
        w.appendSlice(self.sa, ": ") catch return;
        w.print(self.sa, fmt, args) catch return;
        w.append(self.sa, '\n') catch return;
        _ = sys.write_all(2, w.items);
    }

    pub fn msg_raw(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        const m = self.scratch.mark();
        defer self.scratch.release(m);
        const s = std.fmt.allocPrint(self.sa, fmt, args) catch return;
        _ = sys.write_all(2, s);
    }

    pub fn bmsg_noname(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        const m = self.scratch.mark();
        defer self.scratch.release(m);
        var w: std.ArrayList(u8) = .empty;
        w.appendSlice(self.sa, if (self.script_name.len > 0) self.script_name else "zash") catch return;
        w.appendSlice(self.sa, ": ") catch return;
        w.print(self.sa, fmt, args) catch return;
        w.append(self.sa, '\n') catch return;
        _ = sys.write_all(2, w.items);
    }

    pub fn has_func_frame(self: *const Shell) bool {
        for (self.frames.items) |f| if (!f.is_source) return true;
        return false;
    }

    pub fn set_cwd_logical(self: *Shell, p: []const u8) Err!void {
        const c = try self.gpa.dupe(u8, p);
        if (self.cwd_logical.len > 0) self.gpa.free(self.cwd_logical);
        self.cwd_logical = c;
    }

    pub fn xtrace_level(self: *const Shell) u32 {
        return self.cmdsub_depth + 1;
    }

    pub fn set_pos_args(self: *Shell, args: []const []const u8) Err!void {
        return self.set_pos(args);
    }

    pub fn unset_var_raw(self: *Shell, name: []const u8) Err!bool {
        if (self.vars.detach(name)) |v| {
            Vars.destroy(self.gpa, v);
            self.mark_env();
        }
        return true;
    }

    pub fn usage_msg(self: *Shell, name: []const u8, text: []const u8) void {
        self.bmsg(name, "usage: {s}", .{text});
    }

    pub fn mark_env(self: *Shell) void {
        self.env_gen +%= 1;
    }

    pub fn frame_depth(self: *const Shell) u32 {
        return @intCast(self.frames.items.len);
    }

    pub fn find(self: *Shell, name: []const u8) ?*Var {
        var v = self.vars.get(name) orelse return null;
        var n: u32 = 0;
        while (v.flags.nameref) {
            const target = switch (v.value) {
                .str => |s| s,
                else => return v,
            };
            if (target.len == 0) return v;
            if (std.mem.findScalar(u8, target, '[') != null) return v;
            const nv = self.vars.get(target) orelse return null;
            if (nv == v) return null;
            v = nv;
            n += 1;
            if (n > 8) {
                self.msg("warning: {s}: circular name reference", .{name});
                return null;
            }
        }
        return v;
    }

    pub fn nameref_target(self: *Shell, name: []const u8) ?[]const u8 {
        var cur = name;
        var n: u32 = 0;
        while (true) {
            const v = self.vars.get(cur) orelse return if (n == 0) null else cur;
            if (!v.flags.nameref) return if (n == 0) null else cur;
            const t = switch (v.value) {
                .str => |s| s,
                else => return if (n == 0) null else cur,
            };
            if (t.len == 0) return if (n == 0) null else cur;
            cur = t;
            n += 1;
            if (n > 16) return cur;
            if (std.mem.findScalar(u8, cur, '[') != null) return cur;
        }
    }

    pub fn scalar_of(self: *Shell, v: *const Var) ?[]const u8 {
        return switch (v.special) {
            .none => switch (v.value) {
                .none => null,
                .str => |s| s,
                .indexed => |*ix| ix.get(0),
                .assoc => |*m| m.get("0"),
            },
            .random => self.tmp_fmt("{d}", .{self.rng.random().int(u15)}) catch null,
            .lineno => self.tmp_fmt("{d}", .{self.lineno}) catch null,
            .seconds => blk: {
                const el = @divTrunc(sys.mono_ns() - self.start_ns, 1_000_000_000);
                break :blk self.tmp_fmt("{d}", .{el + self.seconds_base}) catch null;
            },
            .bashpid => self.tmp_fmt("{d}", .{self.bashpid}) catch null,
            .epochseconds => self.tmp_fmt("{d}", .{@divTrunc(sys.now_ns(), 1_000_000_000)}) catch null,
            .epochrealtime => blk: {
                const n = sys.now_ns();
                break :blk self.tmp_fmt("{d}.{d:0>6}", .{ @divTrunc(n, 1_000_000_000), @divTrunc(@mod(n, 1_000_000_000), 1000) }) catch null;
            },
            .srandom => self.tmp_fmt("{d}", .{self.rng.random().int(u32)}) catch null,
            else => switch (v.value) {
                .indexed => |*ix| ix.get(0),
                else => null,
            },
        };
    }

    pub fn get_scalar(self: *Shell, name: []const u8) ?[]const u8 {
        const v = self.find(name) orelse return null;
        return self.scalar_of(v);
    }

    pub fn get_or_empty(self: *Shell, name: []const u8) []const u8 {
        return self.get_scalar(name) orelse "";
    }

    pub fn is_valid_name(s: []const u8) bool {
        if (s.len == 0) return false;
        if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
        for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        return true;
    }

    fn apply_case(self: *Shell, v: *const Var, s: []const u8) Err![]const u8 {
        if (!(v.flags.lower or v.flags.upper or v.flags.capital)) return s;
        const out_s = try self.sa.dupe(u8, s);
        if (v.flags.lower) {
            for (out_s) |*c| c.* = std.ascii.toLower(c.*);
        } else if (v.flags.upper) {
            for (out_s) |*c| c.* = std.ascii.toUpper(c.*);
        } else if (out_s.len > 0) {
            for (out_s, 0..) |*c, i| c.* = if (i == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
        }
        return out_s;
    }

    pub fn readonly_err(self: *Shell, name: []const u8) Err {
        self.msg("{s}: readonly variable", .{name});
        self.status = 1;
        return error.Abort;
    }

    pub fn new_var(self: *Shell, name: []const u8) Err!*Var {
        const v = try self.vars.create(self.gpa, name);
        v.depth = 0;
        self.mark_env();
        return v;
    }

    pub fn set_special_assign(self: *Shell, v: *Var, value: []const u8) bool {
        switch (v.special) {
            .random => {
                const n = std.fmt.parseInt(i64, value, 10) catch 0;
                self.rng = std.Random.DefaultPrng.init(@bitCast(n));
                return true;
            },
            .seconds => {
                const n = std.fmt.parseInt(i64, value, 10) catch 0;
                self.start_ns = sys.mono_ns();
                self.seconds_base = n;
                return true;
            },
            .lineno => return true,
            .srandom => return true,
            .bashpid, .epochseconds, .epochrealtime, .funcname, .bash_source, .bash_lineno, .bash_argc, .bash_argv => return true,
            else => return false,
        }
    }

    pub fn set_str_raw(self: *Shell, v: *Var, value: []const u8) Err!void {
        const copy = try self.gpa.dupe(u8, value);
        switch (v.value) {
            .str => |old| {
                self.gpa.free(old);
                v.value = .{ .str = copy };
            },
            .none => v.value = .{ .str = copy },
            .indexed => |*ix| {
                ix.set(self.gpa, 0, value) catch {
                    self.gpa.free(copy);
                    return error.OutOfMemory;
                };
                self.gpa.free(copy);
            },
            .assoc => |*m| {
                m.set(self.gpa, "0", value) catch {
                    self.gpa.free(copy);
                    return error.OutOfMemory;
                };
                self.gpa.free(copy);
            },
        }
        if (v.flags.exported) self.mark_env();
    }

    pub fn eval_int(self: *Shell, text: []const u8) Err!i64 {
        return @import("arith.zig").eval_string(self, text);
    }

    pub fn assign_scalar(self: *Shell, name: []const u8, value: []const u8, append: bool) Err!void {
        var v = self.find(name) orelse blk: {
            if (self.nameref_target(name)) |t| {
                if (std.mem.findScalar(u8, t, '[')) |lb| {
                    if (t[t.len - 1] == ']') return self.assign_elem_text(t[0..lb], t[lb + 1 .. t.len - 1], value, append);
                }
                break :blk try self.new_var(t);
            }
            break :blk try self.new_var(name);
        };
        if (v.flags.nameref and v.special == .none) {
            if (std.mem.findScalar(u8, switch (v.value) {
                .str => |s| s,
                else => "",
            }, '[')) |_| {
                const t = v.value.str;
                const lb = std.mem.findScalar(u8, t, '[').?;
                if (t[t.len - 1] == ']') return self.assign_elem_text(t[0..lb], t[lb + 1 .. t.len - 1], value, append);
            }
        }
        if (v.flags.readonly) return self.readonly_err(v.name);
        if (v.special != .none and self.set_special_assign(v, value)) return;
        var val = value;
        if (v.flags.integer) {
            if (append) {
                const cur = self.scalar_of(v) orelse "0";
                const a = try self.eval_int(cur);
                const b = try self.eval_int(value);
                val = try self.tmp_fmt("{d}", .{a +% b});
            } else {
                val = try self.tmp_fmt("{d}", .{try self.eval_int(value)});
            }
        } else if (append) {
            const cur = self.scalar_of(v) orelse "";
            const joined = try self.sa.alloc(u8, cur.len + value.len);
            @memcpy(joined[0..cur.len], cur);
            @memcpy(joined[cur.len..], value);
            val = joined;
        }
        val = try self.apply_case(v, val);
        if (self.opt(.allexport) and !v.flags.exported) {
            v.flags.exported = true;
        }
        if (v.value == .assoc and v.special == .none) {
            try self.set_str_raw(v, val);
            return;
        }
        try self.set_str_raw(v, val);
    }

    pub fn assign_elem_text(self: *Shell, name: []const u8, sub: []const u8, value: []const u8, append: bool) Err!void {
        const v = self.find(name) orelse try self.new_var(name);
        if (v.flags.readonly) return self.readonly_err(v.name);
        if (v.value == .assoc) {
            return self.assign_assoc(v, sub, value, append);
        }
        const idx = try self.eval_int(sub);
        return self.assign_indexed(v, idx, value, append);
    }

    pub fn assign_assoc(self: *Shell, v: *Var, key: []const u8, value: []const u8, append: bool) Err!void {
        var val = value;
        const cur = v.value.assoc.get(key);
        if (v.flags.integer) {
            if (append) {
                val = try self.tmp_fmt("{d}", .{(try self.eval_int(cur orelse "0")) +% (try self.eval_int(value))});
            } else val = try self.tmp_fmt("{d}", .{try self.eval_int(value)});
        } else if (append) {
            const c = cur orelse "";
            const joined = try self.sa.alloc(u8, c.len + value.len);
            @memcpy(joined[0..c.len], c);
            @memcpy(joined[c.len..], value);
            val = joined;
        }
        val = try self.apply_case(v, val);
        v.value.assoc.set(self.gpa, key, val) catch return error.OutOfMemory;
        if (v.flags.exported) self.mark_env();
    }

    pub fn assign_indexed(self: *Shell, v: *Var, idx_in: i64, value: []const u8, append: bool) Err!void {
        var idx = idx_in;
        switch (v.value) {
            .none => v.value = .{ .indexed = .{} },
            .str => |s| {
                var ix: vars_mod.Indexed = .{};
                ix.set(self.gpa, 0, s) catch return error.OutOfMemory;
                self.gpa.free(s);
                v.value = .{ .indexed = ix };
            },
            else => {},
        }
        const ix = &v.value.indexed;
        if (idx < 0) {
            idx += ix.max_index() + 1;
            if (idx < 0) {
                self.msg("{s}[{d}]: bad array subscript", .{ v.name, idx_in });
                self.status = 1;
                return error.Abort;
            }
        }
        var val = value;
        if (v.flags.integer) {
            if (append) {
                const cur = ix.get(idx) orelse "0";
                val = try self.tmp_fmt("{d}", .{(try self.eval_int(cur)) +% (try self.eval_int(value))});
            } else val = try self.tmp_fmt("{d}", .{try self.eval_int(value)});
        } else if (append) {
            const cur = ix.get(idx) orelse "";
            const joined = try self.sa.alloc(u8, cur.len + value.len);
            @memcpy(joined[0..cur.len], cur);
            @memcpy(joined[cur.len..], value);
            val = joined;
        }
        val = try self.apply_case(v, val);
        ix.set(self.gpa, idx, val) catch return error.OutOfMemory;
        if (v.flags.exported) self.mark_env();
    }

    pub fn declare_indexed(self: *Shell, v: *Var) Err!void {
        switch (v.value) {
            .none => v.value = .{ .indexed = .{} },
            .str => |s| {
                var ix: vars_mod.Indexed = .{};
                ix.set(self.gpa, 0, s) catch return error.OutOfMemory;
                self.gpa.free(s);
                v.value = .{ .indexed = ix };
            },
            else => {},
        }
    }

    pub fn declare_assoc(self: *Shell, v: *Var) Err!void {
        switch (v.value) {
            .none => v.value = .{ .assoc = .{} },
            .str => |s| {
                var m: vars_mod.Assoc = .{};
                m.set(self.gpa, "0", s) catch return error.OutOfMemory;
                self.gpa.free(s);
                v.value = .{ .assoc = m };
            },
            else => {},
        }
    }

    pub fn clear_array(self: *Shell, v: *Var) void {
        switch (v.value) {
            .indexed => |*ix| ix.clear(self.gpa),
            .assoc => |*m| m.clear(self.gpa),
            else => {},
        }
    }

    pub fn export_name(self: *Shell, name: []const u8) Err!void {
        const v = self.find(name) orelse try self.new_var(name);
        v.flags.exported = true;
        self.mark_env();
    }

    pub fn push_local(self: *Shell, name: []const u8) Err!*Var {
        const depth = self.frame_depth();
        if (self.vars.get(name)) |cur| {
            if (cur.depth == depth and depth > 0) return cur;
        }
        const old = self.vars.detach(name);
        const nv = self.vars.create(self.gpa, name) catch |e| {
            if (old) |o| self.vars.attach(self.gpa, o) catch {};
            return e;
        };
        nv.depth = depth;
        nv.flags.local = true;
        if (old) |o| {
            if (o.special != .none) nv.special = o.special;
            if (o.flags.exported and false) nv.flags.exported = true;
        }
        const frame = &self.frames.items[self.frames.items.len - 1];
        try frame.locals.append(self.gpa, .{ .new = nv, .old = old });
        self.mark_env();
        return nv;
    }

    pub fn push_temp(self: *Shell, name: []const u8, value: []const u8) Err!void {
        if (self.vars.get(name)) |cur| {
            if (cur.flags.readonly) return self.readonly_err(name);
        }
        const old = self.vars.detach(name);
        const nv = self.vars.create(self.gpa, name) catch |e| {
            if (old) |o| self.vars.attach(self.gpa, o) catch {};
            return e;
        };
        nv.depth = self.frame_depth();
        nv.flags.exported = true;
        if (old) |o| {
            nv.special = o.special;
            nv.flags.integer = o.flags.integer;
            nv.flags.upper = o.flags.upper;
            nv.flags.lower = o.flags.lower;
            nv.flags.capital = o.flags.capital;
        }
        try self.temps.append(self.gpa, .{ .new = nv, .old = old });
        try self.assign_scalar(name, value, false);
        self.mark_env();
    }

    pub fn pop_temps(self: *Shell, base: usize) void {
        while (self.temps.items.len > base) {
            const s = self.temps.pop().?;
            self.restore_saved(s);
        }
        self.mark_env();
    }

    pub fn restore_saved(self: *Shell, s: Saved) void {
        if (s.new) |nv| {
            if (self.vars.get(nv.name)) |cur| {
                if (cur == nv) {
                    _ = self.vars.detach(nv.name);
                    Vars.destroy(self.gpa, nv);
                } else {
                    return;
                }
            } else Vars.destroy(self.gpa, nv);
        }
        if (s.old) |o| self.vars.attach(self.gpa, o) catch {};
    }

    pub fn pop_locals(self: *Shell, frame: *Frame) void {
        while (frame.locals.items.len > 0) {
            const s = frame.locals.pop().?;
            self.restore_saved(s);
        }
        frame.locals.deinit(self.gpa);
        self.mark_env();
    }

    pub fn unset_var(self: *Shell, name: []const u8) Err!bool {
        const v0 = self.vars.get(name) orelse return true;
        var v = v0;
        if (v.flags.nameref) {
            if (self.find(name)) |t| v = t;
        }
        if (v.flags.readonly) {
            self.bmsg("unset", "{s}: cannot unset: readonly variable", .{v.name});
            return false;
        }
        const depth = self.frame_depth();
        if (v.depth > 0 and v.flags.local) {
            if (v.depth == depth) {
                vars_mod.Vars.deinit_value(self.gpa, v);
                v.flags.exported = false;
                v.flags.integer = false;
                v.flags.upper = false;
                v.flags.lower = false;
                v.flags.capital = false;
                v.flags.nameref = false;
                self.mark_env();
                return true;
            }
            var fi: usize = self.frames.items.len;
            while (fi > 0) {
                fi -= 1;
                const fr = &self.frames.items[fi];
                for (fr.locals.items) |*s| {
                    if (s.new == v) {
                        const old = s.old;
                        s.new = null;
                        s.old = null;
                        _ = self.vars.detach(v.name);
                        Vars.destroy(self.gpa, v);
                        if (old) |o| self.vars.attach(self.gpa, o) catch {};
                        self.mark_env();
                        return true;
                    }
                }
            }
        }
        if (v.depth > 0) {
            vars_mod.Vars.deinit_value(self.gpa, v);
            v.flags.exported = false;
            self.mark_env();
            return true;
        }
        const key = v.name;
        _ = self.vars.detach(key);
        Vars.destroy(self.gpa, v);
        self.mark_env();
        return true;
    }

    pub fn set_pos(self: *Shell, args: []const []const u8) Err!void {
        for (self.pos.items) |p| self.gpa.free(p);
        self.pos.clearRetainingCapacity();
        for (args) |a| {
            const c = try self.gpa.dupe(u8, a);
            self.pos.append(self.gpa, c) catch {
                self.gpa.free(c);
                return error.OutOfMemory;
            };
        }
    }

    pub fn env_block_get(self: *Shell) Err!*EnvBlock {
        if (self.env_built_gen == self.env_gen and self.env_block.ptrs.items.len > 0) return &self.env_block;
        const a = self.gpa;
        for (self.env_block.strings.items) |s| a.free(s);
        self.env_block.strings.clearRetainingCapacity();
        self.env_block.ptrs.clearRetainingCapacity();
        var it = self.vars.map.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (!v.flags.exported) continue;
            const val = switch (v.value) {
                .str => |s| s,
                else => continue,
            };
            const s = try a.allocSentinel(u8, v.name.len + 1 + val.len, 0);
            @memcpy(s[0..v.name.len], v.name);
            s[v.name.len] = '=';
            @memcpy(s[v.name.len + 1 ..], val);
            self.env_block.strings.append(a, s) catch {
                a.free(s);
                return error.OutOfMemory;
            };
        }
        for (self.env_block.strings.items) |s| try self.env_block.ptrs.append(a, s.ptr);
        try self.env_block.ptrs.append(a, null);
        self.env_built_gen = self.env_gen;
        return &self.env_block;
    }

    pub fn ifs(self: *Shell) []const u8 {
        const v = self.vars.get("IFS") orelse return " \t\n";
        return self.scalar_of(v) orelse if (v.value == .none) " \t\n" else "";
    }

    pub fn add_job(self: *Shell, pid: i32, cmd: []const u8) Err!void {
        const c = try self.gpa.dupe(u8, cmd);
        try self.jobs.append(self.gpa, .{ .pid = pid, .cmd = c, .id = self.next_job_id });
        self.next_job_id += 1;
    }

    pub fn find_job(self: *Shell, pid: i32) ?*Job {
        for (self.jobs.items) |*j| if (j.pid == pid) return j;
        return null;
    }
};

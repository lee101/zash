const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const registry = @import("../utils/registry.zig");
const builtins = @import("builtins.zig");
const pspawn = @import("pspawn.zig");
const exec = @import("exec.zig");
const plan = @import("plan.zig");
const common = @import("../utils/common.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Io = std.Io;

const use_asm = builtin.cpu.arch == .x86_64;

pub const supported = builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or (builtin.cpu.arch == .aarch64 and builtin.abi.isGnu()));

const UContext = extern struct {
    flags: usize,
    link: ?*UContext,
    ss_sp: ?*anyopaque,
    ss_flags: c_int,
    ss_size: usize,
    rest: [4096]u8 align(16),
};

const uc = if (use_asm) struct {} else struct {
    extern "c" fn getcontext(uc: *UContext) c_int;
    extern "c" fn makecontext(uc: *UContext, func: *const fn () callconv(.c) void, argc: c_int, ...) void;
    extern "c" fn swapcontext(old: *UContext, new: *const UContext) c_int;
};

const Ctx = if (use_asm) struct { sp: usize = 0 } else UContext;

fn ctx_switch_asm() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\pushq %%rbp
            \\pushq %%rbx
            \\pushq %%r12
            \\pushq %%r13
            \\pushq %%r14
            \\pushq %%r15
            \\movq %%rsp, (%%rdi)
            \\movq (%%rsi), %%rsp
            \\popq %%r15
            \\popq %%r14
            \\popq %%r13
            \\popq %%r12
            \\popq %%rbx
            \\popq %%rbp
            \\retq
        ),
        else => unreachable,
    }
}

const SwitchFn = *const fn (*usize, *const usize) callconv(.c) void;

fn ctx_switch(from: *Ctx, to: *Ctx) void {
    if (use_asm) @as(SwitchFn, @ptrCast(&ctx_switch_asm))(&from.sp, &to.sp) else _ = uc.swapcontext(from, to);
}

fn ctx_init(c: *Ctx, stack: []u8, entry: *const fn () callconv(.c) void) void {
    if (use_asm) {
        const top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16);
        switch (builtin.cpu.arch) {
            .x86_64 => {
                const frame: [*]usize = @ptrFromInt(top - 64);
                @memset(frame[0..6], 0);
                frame[6] = @intFromPtr(entry);
                frame[7] = 0;
                c.sp = top - 64;
            },
            else => unreachable,
        }
    } else {
        _ = uc.getcontext(c);
        c.ss_sp = stack.ptr;
        c.ss_size = stack.len;
        c.link = null;
        uc.makecontext(c, entry, 0);
    }
}

const stack_size: usize = 1 << 20;
const ring_size: usize = 64 * 1024;

const Group = struct {
    main_ctx: Ctx = undefined,
    running: ?*Fiber = null,
    progress: u64 = 0,
    aborted: bool = false,
};

const Fiber = struct {
    ctx: Ctx = undefined,
    stack: []u8 = &.{},
    done: bool = false,
    group: *Group,
    stage: *Stage,
    wait_fd: c_int = -1,
    wait_ev: c_short = 0,
};

fn wait_on_fd(g: *Group, fd: c_int, ev: c_short) void {
    const f = g.running.?;
    f.wait_fd = fd;
    f.wait_ev = ev;
    yield(g);
    f.wait_fd = -1;
}

var stack_pool: [16][]u8 = undefined;
var stack_pool_n: usize = 0;

fn stack_get(sh: *Shell) ![]u8 {
    if (stack_pool_n > 0) {
        stack_pool_n -= 1;
        return stack_pool[stack_pool_n];
    }
    return sh.gpa.alloc(u8, stack_size);
}

fn stack_put(sh: *Shell, st: []u8) void {
    if (stack_pool_n < stack_pool.len) {
        stack_pool[stack_pool_n] = st;
        stack_pool_n += 1;
    } else sh.gpa.free(st);
}

var active_group: ?*Group = null;

fn yield(g: *Group) void {
    const f = g.running.?;
    ctx_switch(&f.ctx, &g.main_ctx);
}

fn fiber_entry() callconv(.c) void {
    const g = active_group.?;
    const f = g.running.?;
    stage_main(f.stage);
    f.done = true;
    while (true) yield(g);
}

const Ring = struct {
    buf: []u8,
    head: usize = 0,
    len: usize = 0,
    writer_done: bool = false,
    reader_closed: bool = false,
};

const RingWriter = struct {
    ring: *Ring,
    group: *Group,
    w: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *RingWriter = @alignCast(@fieldParentPtr("w", w));
        try self.put_all(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |s| {
            try self.put_all(s);
            n += s.len;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            try self.put_all(last);
            n += last.len;
        }
        if (self.ring.len > 0) yield(self.group);
        return n;
    }

    fn put_all(self: *RingWriter, bytes: []const u8) Io.Writer.Error!void {
        const r = self.ring;
        var rest = bytes;
        while (rest.len > 0) {
            if (r.reader_closed or self.group.aborted) return error.WriteFailed;
            const space = r.buf.len - r.len;
            if (space == 0) {
                yield(self.group);
                continue;
            }
            const n = @min(space, rest.len);
            var tail = (r.head + r.len) % r.buf.len;
            var left = n;
            var src = rest;
            while (left > 0) {
                const chunk = @min(left, r.buf.len - tail);
                @memcpy(r.buf[tail .. tail + chunk], src[0..chunk]);
                tail = (tail + chunk) % r.buf.len;
                src = src[chunk..];
                left -= chunk;
            }
            r.len += n;
            self.group.progress += 1;
            rest = rest[n..];
        }
    }
};

const RingReader = struct {
    ring: *Ring,
    group: *Group,
    r: Io.Reader,

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *RingReader = @alignCast(@fieldParentPtr("r", r));
        const ring = self.ring;
        while (true) {
            if (ring.len > 0) {
                const dest = limit.slice(try w.writableSliceGreedy(1));
                const n = @min(dest.len, ring.len);
                var got: usize = 0;
                while (got < n) {
                    const chunk = @min(n - got, ring.buf.len - ring.head);
                    @memcpy(dest[got .. got + chunk], ring.buf[ring.head .. ring.head + chunk]);
                    ring.head = (ring.head + chunk) % ring.buf.len;
                    got += chunk;
                }
                ring.len -= n;
                w.advance(n);
                self.group.progress += 1;
                return n;
            }
            if (ring.writer_done or self.group.aborted) return error.EndOfStream;
            yield(self.group);
        }
    }
};

const FdReader = struct {
    fd: c_int,
    group: *Group,
    r: Io.Reader,

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *FdReader = @alignCast(@fieldParentPtr("r", r));
        while (true) {
            if (self.group.aborted) return error.EndOfStream;
            const dest = limit.slice(try w.writableSliceGreedy(1));
            const n = sys.read(self.fd, dest.ptr, dest.len);
            if (n > 0) {
                w.advance(@intCast(n));
                self.group.progress += 1;
                return @intCast(n);
            }
            if (n == 0) return error.EndOfStream;
            const e = sys.errno();
            if (e == sys.EINTR) continue;
            if (e == sys.EAGAIN) {
                wait_on_fd(self.group, self.fd, sys.POLLIN);
                continue;
            }
            return error.ReadFailed;
        }
    }
};

const MemWriter = struct {
    list: *std.ArrayList(u8),
    a: std.mem.Allocator,
    w: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *MemWriter = @alignCast(@fieldParentPtr("w", w));
        self.list.appendSlice(self.a, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |s| {
            self.list.appendSlice(self.a, s) catch return error.WriteFailed;
            n += s.len;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            self.list.appendSlice(self.a, last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

const FdWriter = struct {
    fd: c_int,
    group: *Group,
    w: Io.Writer,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("w", w));
        try self.put_all(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |s| {
            try self.put_all(s);
            n += s.len;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            try self.put_all(last);
            n += last.len;
        }
        return n;
    }

    fn put_all(self: *FdWriter, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.group.aborted) return error.WriteFailed;
            const n = sys.write(self.fd, rest.ptr, rest.len);
            if (n > 0) {
                rest = rest[@intCast(n)..];
                self.group.progress += 1;
                continue;
            }
            const e = sys.errno();
            if (e == sys.EINTR) continue;
            if (e == sys.EAGAIN) {
                wait_on_fd(self.group, self.fd, sys.POLLOUT);
                continue;
            }
            return error.WriteFailed;
        }
    }
};

const Kind = enum { util, ext };

const Source = union(enum) {
    fd: c_int,
    ring: *Ring,
    pipe: c_int,
    none,
};

const Sink = struct {
    fd: c_int = -1,
    ring: ?*Ring = null,
    nonblock: bool = false,
    close_fd: c_int = -1,
    closed: bool = false,
    inited: bool = false,
    a: std.mem.Allocator,
    gpa: std.mem.Allocator = undefined,
    io: Io,
    group: *Group,
    file_w: ?*Io.File.Writer = null,
    ring_w: ?*RingWriter = null,
    fd_w: ?*FdWriter = null,
    mem: ?*std.ArrayList(u8) = null,
    mem_w: ?*MemWriter = null,

    fn writer(self: *Sink) *Io.Writer {
        if (!self.inited) self.init_writer() catch @panic("oom");
        if (self.mem_w) |mw| return &mw.w;
        if (self.ring_w) |rw| return &rw.w;
        if (self.fd_w) |fw| return &fw.w;
        return &self.file_w.?.interface;
    }

    fn init_writer(self: *Sink) !void {
        self.inited = true;
        if (self.mem) |list| {
            const mw = try self.a.create(MemWriter);
            mw.* = .{ .list = list, .a = self.a, .w = .{
                .vtable = &.{ .drain = MemWriter.drain },
                .buffer = try self.a.alloc(u8, 4096),
            } };
            self.mem_w = mw;
        } else if (self.ring) |ring| {
            const rw = try self.a.create(RingWriter);
            rw.* = .{ .ring = ring, .group = self.group, .w = .{
                .vtable = &.{ .drain = RingWriter.drain },
                .buffer = try self.a.alloc(u8, 8192),
            } };
            self.ring_w = rw;
        } else if (self.nonblock) {
            const fw = try self.a.create(FdWriter);
            fw.* = .{ .fd = self.fd, .group = self.group, .w = .{
                .vtable = &.{ .drain = FdWriter.drain },
                .buffer = try self.a.alloc(u8, 8192),
            } };
            self.fd_w = fw;
        } else {
            const fw = try self.a.create(Io.File.Writer);
            const f: Io.File = .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
            fw.* = f.writerStreaming(self.io, try self.a.alloc(u8, if (self.fd == 2) 4096 else 65536));
            self.file_w = fw;
        }
    }

    fn flush(self: *Sink) void {
        if (self.inited) self.writer().flush() catch {};
    }

    fn close_pipe(self: *Sink) void {
        if (self.close_fd >= 0 and !self.closed) _ = sys.close(self.close_fd);
        self.closed = true;
    }
};

const Stage = struct {
    argv: []const []const u8,
    kind: Kind = .util,
    run_fn: ?common.UtilFn = null,
    path: []const u8 = "",
    src: Source = .none,
    in_close: c_int = -1,
    out_ring: ?*Ring = null,
    sink_out: *Sink = undefined,
    sink_err: *Sink = undefined,
    status: u8 = 0,
    failed_open: bool = false,
    elided: bool = false,
    pre: ?[]const u8 = null,
    builtin: bool = false,
    pid: c_int = -1,
    sh: *Shell,
    group: *Group,
    env: *const common.EnvView,
    cwd: []const u8,
    in_buf: []u8 = &.{},
    file_r: Io.File.Reader = undefined,
    ring_r: RingReader = undefined,
    fd_r: FdReader = undefined,
};

fn stage_main(st: *Stage) void {
    if (st.pre) |bytes| {
        st.sink_out.writer().writeAll(bytes) catch {};
        finish_stage(st);
        return;
    }
    if (st.failed_open) {
        st.status = 1;
        finish_stage(st);
        return;
    }
    var empty_r: Io.Reader = Io.Reader.fixed("");
    var in_reader: *Io.Reader = &empty_r;
    switch (st.src) {
        .fd => |fd| {
            const f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            st.file_r = f.readerStreaming(st.sh.io, st.in_buf);
            in_reader = &st.file_r.interface;
        },
        .ring => |ring| {
            st.ring_r = .{ .ring = ring, .group = st.group, .r = .{
                .vtable = &.{ .stream = RingReader.stream },
                .buffer = st.in_buf,
                .seek = 0,
                .end = 0,
            } };
            in_reader = &st.ring_r.r;
        },
        .pipe => |fd| {
            st.fd_r = .{ .fd = fd, .group = st.group, .r = .{
                .vtable = &.{ .stream = FdReader.stream },
                .buffer = st.in_buf,
                .seek = 0,
                .end = 0,
            } };
            in_reader = &st.fd_r.r;
        },
        .none => {},
    }
    var ctx: common.Ctx = .{ .alloc = st.sh.gpa, .io = st.sh.io, .cwd = st.cwd, .env = st.env };
    if (std.mem.eql(u8, st.argv[0], "grep") and st.sink_out.fd >= 0) {
        if (sys.stat_fd(st.sink_out.fd)) |s1| ctx.out_null = s1.is_dev_null();
    }
    st.status = st.run_fn.?(&ctx, st.argv, .{ .in = in_reader, .out = st.sink_out.writer(), .err = st.sink_err.writer() });
    finish_stage(st);
}

fn finish_stage(st: *Stage) void {
    st.sink_out.flush();
    st.sink_err.flush();
    st.sink_out.close_pipe();
    st.sink_err.close_pipe();
    if (st.out_ring) |r| r.writer_done = true;
    if (st.sink_out.ring) |r| r.writer_done = true;
    if (st.sink_err.ring) |r| r.writer_done = true;
    switch (st.src) {
        .ring => |r| r.reader_closed = true,
        else => {},
    }
    if (st.in_close >= 0) {
        _ = sys.close(st.in_close);
        st.in_close = -1;
    }
    st.group.progress += 1;
}

const Edge = struct {
    ring: ?*Ring = null,
    r: c_int = -1,
    w: c_int = -1,
};

const Build = struct {
    sh: *Shell,
    a: std.mem.Allocator,
    group: *Group,
    opened: std.ArrayList(c_int) = .empty,
    live: std.ArrayList(c_int) = .empty,

    fn bail(self: *Build) ?u8 {
        for (self.opened.items) |fd| _ = sys.close(fd);
        self.opened.clearRetainingCapacity();
        for (self.live.items) |fd| _ = sys.close(fd);
        self.live.clearRetainingCapacity();
        return null;
    }

    fn closef(self: *Build, fd: c_int) void {
        _ = sys.close(fd);
        for (self.live.items, 0..) |x, i| {
            if (x == fd) {
                _ = self.live.swapRemove(i);
                break;
            }
        }
    }

    fn close_sink_pipe(self: *Build, s: *Sink) void {
        if (s.close_fd >= 0 and !s.closed) self.closef(s.close_fd);
        s.closed = true;
    }

    fn new_ring(self: *Build) Err!*Ring {
        const r = try self.a.create(Ring);
        r.* = .{ .buf = try self.a.alloc(u8, ring_size) };
        return r;
    }

    fn sink(self: *Build, fd: c_int, own: bool) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .fd = fd, .a = self.a, .io = self.sh.io, .group = self.group };
        if (own) try self.opened.append(self.a, fd);
        return s;
    }

    fn sink_mem(self: *Build, list: *std.ArrayList(u8)) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .mem = list, .a = self.a, .gpa = self.sh.gpa, .io = self.sh.io, .group = self.group };
        return s;
    }

    fn sink_ring(self: *Build, ring: *Ring) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .ring = ring, .a = self.a, .io = self.sh.io, .group = self.group };
        return s;
    }

    fn sink_pipe(self: *Build, fd: c_int, nonblock: bool) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .fd = fd, .close_fd = fd, .nonblock = nonblock, .a = self.a, .io = self.sh.io, .group = self.group };
        return s;
    }
};

fn open_target(sh: *Shell, w: ast.Word, flags: c_int) Err!?c_int {
    var fields: std.ArrayList([]const u8) = .empty;
    try expand.word_fields(sh, w, &fields);
    if (fields.items.len != 1) return null;
    const path = fields.items[0];
    var buf: [4096]u8 = undefined;
    const z = sys.cstr(&buf, path) orelse return null;
    const fd = sys.open(z, flags | sys.O.CLOEXEC, @as(c_uint, 0o666));
    if (fd < 0) {
        sh.msg("{s}: {s}", .{ path, sys.msg_for(sys.errno()) });
        return -1;
    }
    return fd;
}

fn set_nonblock(fd: c_int) void {
    const fl = sys.fcntl(fd, sys.F_GETFL);
    if (fl >= 0) _ = sys.fcntl(fd, sys.F_SETFL, fl | sys.O.NONBLOCK);
}

fn has_stdin_redir(redirs: []const ast.Redirect) bool {
    for (redirs) |r| {
        switch (r.op) {
            .in, .dup_in, .read_write, .here_str, .heredoc, .heredoc_strip => {
                if (r.fd == .none or (r.fd == .num and r.fd.num == 0)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn spawn_ext(sh: *Shell, st: *Stage, envp: [*:null]const ?[*:0]const u8, default_sigpipe: bool, old_pipe: usize) void {
    const argz = exec.make_argv_z(sh, st.argv) catch {
        st.status = 1;
        return;
    };
    var pbuf: [4096]u8 = undefined;
    const pz = sys.cstr(&pbuf, st.path) orelse {
        st.status = 126;
        return;
    };
    const in_fd: c_int = switch (st.src) {
        .fd => |f| f,
        .pipe => |f| f,
        else => 0,
    };
    const out_fd = st.sink_out.fd;
    const err_fd = st.sink_err.fd;
    var sp: pspawn.Spawn = .{};
    if (sp.init(default_sigpipe)) {
        defer sp.deinit();
        var ok = true;
        if (in_fd != 0) ok = ok and sp.dup2(in_fd, 0);
        if (out_fd != 1) ok = ok and sp.dup2(out_fd, 1);
        if (err_fd != 2) ok = ok and sp.dup2(err_fd, 2);
        if (ok) {
            var pid: c_int = 0;
            if (sp.go(&pid, pz.ptr, argz, envp) == 0) {
                st.pid = pid;
                return;
            }
        }
    }
    const pid = sys.fork();
    if (pid < 0) {
        sh.msg("fork: {s}", .{sys.msg_for(sys.errno())});
        st.status = 1;
        return;
    }
    if (pid == 0) {
        if (in_fd != 0) _ = sys.dup2(in_fd, 0);
        if (out_fd != 1) _ = sys.dup2(out_fd, 1);
        if (err_fd != 2) _ = sys.dup2(err_fd, 2);
        sys.set_signal(sys.SIGPIPE, old_pipe);
        exec.child_prepare_exec(sh);
        _ = sys.execve(pz.ptr, argz, envp);
        sys._exit(exec.exec_failed(sh, st.path, st.argv));
    }
    st.pid = pid;
}

fn poll_waiters(fibers: []Fiber, fds: []sys.PollFd) void {
    var k: usize = 0;
    for (fibers) |*f| {
        if (f.done or f.wait_fd < 0) continue;
        fds[k] = .{ .fd = f.wait_fd, .events = f.wait_ev, .revents = 0 };
        k += 1;
    }
    if (k == 0) return;
    _ = sys.poll(fds.ptr, k, -1);
}

pub fn run(sh: *Shell, p: ast.Pipeline, cap: ?*std.ArrayList(u8)) Err!?u8 {
    if (!supported) return null;
    const a = sh.sa;
    const n_real = p.commands.len;
    var stages = try a.alloc(Stage, n_real + 1);
    var util_count: usize = 0;
    for (p.commands, 0..) |c, i| {
        const s = c.body.simple;
        var list: std.ArrayList([]const u8) = .empty;
        sh.lineno = c.line;
        try expand.words_fields(sh, s.words, &list);
        if (list.items.len == 0) return null;
        const name = list.items[0];
        if (sh.funcs.contains(name)) return null;
        if (builtins.is_builtin(name)) {
            if (!plan.pure_builtin(name) or c.redirs.len != 0) return null;
            if (list.items.len > 1 and (std.mem.eql(u8, list.items[1], "--help") or (std.mem.eql(u8, name, "printf") and std.mem.eql(u8, list.items[1], "-v")))) return null;
        }
        if (sh.pending_funcs.count() > 0 and sh.pending_funcs.contains(name)) return null;
        if (sh.aliases.count() > 0 and sh.aliases.contains(name)) return null;
        var st: Stage = .{ .argv = list.items, .sh = sh, .group = undefined, .env = undefined, .cwd = undefined };
        if (builtins.is_builtin(name)) {
            st.builtin = true;
            util_count += 1;
            stages[i] = st;
            continue;
        }
        if (registry.lookup(name)) |rf| {
            if (registry.supports(list.items) and exec.util_ok_stage(sh, name, c.redirs, i == 0)) {
                st.run_fn = rf;
                util_count += 1;
            } else st.kind = .ext;
        } else st.kind = .ext;
        if (st.kind == .ext) {
            const r = exec.resolve(sh, name, true) catch return null;
            switch (r) {
                .found => |pth| {
                    if (!exec.exec_magic_ok(sh, pth)) return null;
                    st.path = pth;
                },
                else => return null,
            }
        }
        stages[i] = st;
    }

    var n = n_real;
    if (cap != null and stages[n_real - 1].kind == .ext) {
        const cat_fn = registry.lookup("cat") orelse return null;
        stages[n_real] = .{ .argv = &.{"cat"}, .run_fn = cat_fn, .sh = sh, .group = undefined, .env = undefined, .cwd = undefined };
        util_count += 1;
        n += 1;
    }
    stages = stages[0..n];

    var group: Group = .{};
    var b: Build = .{ .sh = sh, .a = a, .group = &group };

    var cat_fd: c_int = -1;
    if (n_real >= 2 and stages[0].kind == .util and stages[0].argv.len == 2 and std.mem.eql(u8, stages[0].argv[0], "cat") and p.commands[0].redirs.len == 0 and
        !has_stdin_redir(p.commands[1].redirs) and !(i_pipe_stderr(p, 0)))
    {
        const f = stages[0].argv[1];
        if (f.len > 0 and f[0] != '-') {
            var buf: [4096]u8 = undefined;
            if (sys.cstr(&buf, f)) |z| {
                const fd = sys.open(z, sys.O.RDONLY | sys.O.CLOEXEC);
                if (fd >= 0) {
                    if (sys.stat_fd(fd)) |stt| {
                        if (stt.is_reg()) cat_fd = fd else _ = sys.close(fd);
                    } else _ = sys.close(fd);
                }
            }
        }
    }
    if (cat_fd >= 0) {
        stages[0].elided = true;
        util_count -= 1;
        try b.opened.append(a, cat_fd);
    }

    const stdout_default = if (cap) |c| try b.sink_mem(c) else try b.sink(1, false);
    const stderr_default = try b.sink(2, false);

    const edges = try a.alloc(Edge, n - 1);
    for (edges, 0..) |*e, i| {
        e.* = .{};
        if (stages[i].elided) continue;
        if (stages[i].kind == .util and stages[i + 1].kind == .util) {
            e.ring = try b.new_ring();
        } else {
            var fds: [2]c_int = undefined;
            if (sys.pipe2(&fds, sys.O.CLOEXEC) != 0) return b.bail();
            e.r = fds[0];
            e.w = fds[1];
            try b.live.append(a, fds[0]);
            try b.live.append(a, fds[1]);
            if (stages[i].kind == .util) set_nonblock(e.w);
            if (stages[i + 1].kind == .util) set_nonblock(e.r);
        }
    }

    const Env = struct {
        pairs: []const [2][]const u8,
        fn get(c: ?*const anyopaque, key: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(c.?));
            for (self.pairs) |pr| if (std.mem.eql(u8, pr[0], key)) return pr[1];
            return null;
        }
    };
    var pairs: std.ArrayList([2][]const u8) = .empty;
    if (util_count > 0) {
        var vit = sh.vars.map.iterator();
        while (vit.next()) |e| {
            const v = e.value_ptr.*;
            switch (v.value) {
                .str => |s| try pairs.append(a, .{ v.name, s }),
                else => {},
            }
        }
    }
    var env_ctx: Env = .{ .pairs = pairs.items };
    const env: common.EnvView = .{ .context = &env_ctx, .get_fn = Env.get };
    const cwd = sh.get_scalar("PWD") orelse ".";

    const pipe_sinks = try a.alloc(*Sink, n);
    for (0..n) |i| {
        pipe_sinks[i] = stdout_default;
        if (i + 1 < n and !stages[i].elided) {
            const e = edges[i];
            pipe_sinks[i] = if (e.ring) |r| try b.sink_ring(r) else try b.sink_pipe(e.w, stages[i].kind == .util);
        }
    }

    for (0..n) |i| {
        const redirs: []const ast.Redirect = if (i < n_real) p.commands[i].redirs else &.{};
        var st = &stages[i];
        st.group = &group;
        st.env = &env;
        st.cwd = cwd;
        if (st.elided) continue;
        if (st.kind == .util and !st.builtin) st.in_buf = try a.alloc(u8, 65536);
        if (i == 0) {
            st.src = .{ .fd = 0 };
        } else if (stages[i - 1].elided) {
            st.src = .{ .fd = cat_fd };
        } else {
            const e = edges[i - 1];
            if (e.ring) |r| st.src = .{ .ring = r } else {
                st.src = .{ .pipe = e.r };
                st.in_close = e.r;
            }
        }
        if (i + 1 < n and !stages[i].elided) st.out_ring = edges[i].ring;
        var fd1: *Sink = pipe_sinks[i];
        var fd2: *Sink = if (i < p.pipe_stderr.len and p.pipe_stderr[i] and i + 1 < n) pipe_sinks[i] else stderr_default;
        for (redirs) |r| {
            const target_fd: c_int = switch (r.fd) {
                .none => switch (r.op) {
                    .in => 0,
                    else => 1,
                },
                .num => |x| @intCast(x),
                .named => return b.bail(),
            };
            switch (r.op) {
                .in => {
                    if (target_fd != 0) return b.bail();
                    const fd = (try open_target(sh, r.target, sys.O.RDONLY)) orelse return b.bail();
                    if (fd < 0) {
                        st.failed_open = true;
                        continue;
                    }
                    try b.opened.append(a, fd);
                    switch (st.src) {
                        .ring => |ring| ring.reader_closed = true,
                        else => {},
                    }
                    if (st.in_close >= 0) {
                        b.closef(st.in_close);
                        st.in_close = -1;
                    }
                    st.src = .{ .fd = fd };
                },
                .out, .append, .clobber, .out_err, .append_err => {
                    if (r.op == .out and sh.opt(.noclobber)) return b.bail();
                    const flags: c_int = switch (r.op) {
                        .append, .append_err => sys.O.WRONLY | sys.O.CREAT | sys.O.APPEND,
                        else => sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC,
                    };
                    const fd = (try open_target(sh, r.target, flags)) orelse return b.bail();
                    if (fd < 0) {
                        st.failed_open = true;
                        continue;
                    }
                    const sink = try b.sink(fd, true);
                    if (r.op == .out_err or r.op == .append_err) {
                        fd1 = sink;
                        fd2 = sink;
                    } else if (target_fd == 1) fd1 = sink else if (target_fd == 2) fd2 = sink else return b.bail();
                },
                .dup_out => {
                    const word = try expand.word_string(sh, r.target);
                    if (std.mem.eql(u8, word, "1")) {
                        if (target_fd == 2) fd2 = fd1 else if (target_fd != 1) return b.bail();
                    } else if (std.mem.eql(u8, word, "2")) {
                        if (target_fd == 1) fd1 = fd2 else if (target_fd != 2) return b.bail();
                    } else return b.bail();
                },
                else => return b.bail(),
            }
        }
        st.sink_out = fd1;
        st.sink_err = fd2;
        if (i + 1 < n) {
            const ps = pipe_sinks[i];
            if (ps.close_fd >= 0 and fd1 != ps and fd2 != ps) b.close_sink_pipe(ps);
        }
    }

    for (stages) |*st| {
        if (!st.builtin) continue;
        var buf: std.ArrayList(u8) = .empty;
        const prev = sh.capture;
        sh.capture = &buf;
        defer sh.capture = prev;
        const bi = builtins.lookup(st.argv[0]).?;
        st.status = bi.run(sh, st.argv) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => sh.status,
        };
        st.pre = buf.items;
    }

    if (sh.opt(.xtrace)) {
        for (stages) |st| try exec.trace_argv(sh, st.argv);
    }

    const old_pipe = sys.get_signal(sys.SIGPIPE);
    const default_sigpipe = old_pipe == sys.SIG_DFL;
    var envp: [*:null]const ?[*:0]const u8 = undefined;
    if (util_count < n) {
        const env_block = try sh.env_block_get();
        envp = @ptrCast(env_block.ptrs.items.ptr);
    }
    for (stages) |*st| {
        if (st.elided or st.kind != .ext) continue;
        if (st.failed_open) {
            st.status = 1;
        } else spawn_ext(sh, st, envp, default_sigpipe, old_pipe);
        if (st.in_close >= 0) {
            _ = sys.close(st.in_close);
            st.in_close = -1;
        }
        st.sink_out.close_pipe();
        st.sink_err.close_pipe();
    }

    if (util_count > 0) {
        const fibers = try a.alloc(Fiber, util_count);
        var fi: usize = 0;
        for (stages) |*st| {
            if (st.elided or st.kind != .util) continue;
            const f = &fibers[fi];
            fi += 1;
            f.* = .{ .group = &group, .stage = st };
            f.stack = try stack_get(sh);
            ctx_init(&f.ctx, f.stack, &fiber_entry);
        }
        defer for (fibers) |f| stack_put(sh, f.stack);
        const pfds = try a.alloc(sys.PollFd, util_count);

        sys.set_signal(sys.SIGPIPE, sys.SIG_IGN);
        defer sys.set_signal(sys.SIGPIPE, old_pipe);

        const saved_active = active_group;
        active_group = &group;
        defer active_group = saved_active;

        var idle_passes: u32 = 0;
        while (true) {
            var alive = false;
            var progressed = false;
            var waiting = false;
            for (fibers) |*f| {
                if (f.done) continue;
                alive = true;
                const mark = group.progress;
                group.running = f;
                ctx_switch(&group.main_ctx, &f.ctx);
                group.running = null;
                if (f.done or group.progress != mark) progressed = true;
                if (!f.done and f.wait_fd >= 0) waiting = true;
            }
            if (!alive) break;
            if (progressed) {
                idle_passes = 0;
            } else if (waiting) {
                poll_waiters(fibers, pfds);
                idle_passes = 0;
            } else {
                idle_passes += 1;
                if (idle_passes > 4) group.aborted = true;
            }
        }
    }
    for (b.opened.items) |fd| _ = sys.close(fd);

    const sts = try a.alloc(u8, n_real);
    for (stages, 0..) |*st, i| {
        if (st.kind == .ext and st.pid > 0) st.status = exec.wait_pid(sh, st.pid);
        if (i < n_real) sts[i] = st.status;
    }
    if (cap == null) exec.set_pipestatus_pub(sh, sts);
    var result = sts[n_real - 1];
    if (sh.opt(.pipefail)) {
        var k = n_real;
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

fn i_pipe_stderr(p: ast.Pipeline, i: usize) bool {
    return i < p.pipe_stderr.len and p.pipe_stderr[i];
}

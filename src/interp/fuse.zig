const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const expand = @import("expand.zig");
const registry = @import("../utils/registry.zig");
const common = @import("../utils/common.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Io = std.Io;

pub const supported = builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

const UContext = extern struct {
    flags: usize,
    link: ?*UContext,
    ss_sp: ?*anyopaque,
    ss_flags: c_int,
    ss_size: usize,
    rest: [4096]u8 align(16),
};

extern "c" fn getcontext(uc: *UContext) c_int;
extern "c" fn makecontext(uc: *UContext, func: *const fn () callconv(.c) void, argc: c_int, ...) void;
extern "c" fn swapcontext(old: *UContext, new: *const UContext) c_int;

const stack_size: usize = 1 << 20;
const ring_size: usize = 64 * 1024;

const Group = struct {
    main_ctx: UContext = undefined,
    running: ?*Fiber = null,
    progress: u64 = 0,
    aborted: bool = false,
};

const Fiber = struct {
    ctx: UContext = undefined,
    stack: []u8 = &.{},
    done: bool = false,
    group: *Group,
    stage: *Stage,
};

var active_group: ?*Group = null;

fn yield(g: *Group) void {
    const f = g.running.?;
    _ = swapcontext(&f.ctx, &g.main_ctx);
}

fn fiber_entry() callconv(.c) void {
    const g = active_group.?;
    const f = g.running.?;
    stage_main(f.stage);
    f.done = true;
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

const Source = union(enum) {
    fd: c_int,
    ring: *Ring,
    none,
};

const Sink = struct {
    fd: c_int = -1,
    ring: ?*Ring = null,
    file_w: ?*Io.File.Writer = null,
    ring_w: ?*RingWriter = null,
    buf: []u8 = &.{},

    fn writer(self: *Sink) *Io.Writer {
        if (self.ring_w) |rw| return &rw.w;
        return &self.file_w.?.interface;
    }
};

const Stage = struct {
    argv: []const []const u8,
    run_fn: common.UtilFn,
    src: Source = .none,
    sink_out: *Sink = undefined,
    sink_err: *Sink = undefined,
    status: u8 = 0,
    failed_open: bool = false,
    sh: *Shell,
    group: *Group,
    env: *const common.EnvView,
    cwd: []const u8,
    in_buf: []u8 = &.{},
    file_r: Io.File.Reader = undefined,
    ring_r: RingReader = undefined,
};

fn stage_main(st: *Stage) void {
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
        .none => {},
    }
    var ctx: common.Ctx = .{ .alloc = st.sh.gpa, .io = st.sh.io, .cwd = st.cwd, .env = st.env };
    st.status = st.run_fn(&ctx, st.argv, .{ .in = in_reader, .out = st.sink_out.writer(), .err = st.sink_err.writer() });
    finish_stage(st);
}

fn finish_stage(st: *Stage) void {
    st.sink_out.writer().flush() catch {};
    st.sink_err.writer().flush() catch {};
    if (st.sink_out.ring) |r| r.writer_done = true;
    if (st.sink_err.ring) |r| r.writer_done = true;
    switch (st.src) {
        .ring => |r| r.reader_closed = true,
        else => {},
    }
    st.group.progress += 1;
}

const Build = struct {
    sh: *Shell,
    a: std.mem.Allocator,
    group: *Group,
    sinks: std.ArrayList(*Sink) = .empty,
    opened: std.ArrayList(c_int) = .empty,
    rings: std.ArrayList(*Ring) = .empty,

    fn bail(self: *Build) ?u8 {
        for (self.opened.items) |fd| _ = sys.close(fd);
        self.opened.clearRetainingCapacity();
        return null;
    }

    fn new_ring(self: *Build) Err!*Ring {
        const r = try self.a.create(Ring);
        r.* = .{ .buf = try self.a.alloc(u8, ring_size) };
        try self.rings.append(self.a, r);
        return r;
    }

    fn sink_fd(self: *Build, fd: c_int, own: bool) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .fd = fd };
        s.buf = try self.a.alloc(u8, if (fd == 2) 4096 else 65536);
        const fw = try self.a.create(Io.File.Writer);
        const f: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        fw.* = f.writerStreaming(self.sh.io, s.buf);
        s.file_w = fw;
        try self.sinks.append(self.a, s);
        if (own) try self.opened.append(self.a, fd);
        return s;
    }

    fn sink_ring(self: *Build, ring: *Ring) Err!*Sink {
        const s = try self.a.create(Sink);
        s.* = .{ .ring = ring };
        s.buf = try self.a.alloc(u8, 16384);
        const rw = try self.a.create(RingWriter);
        rw.* = .{ .ring = ring, .group = self.group, .w = .{
            .vtable = &.{ .drain = RingWriter.drain },
            .buffer = s.buf,
        } };
        s.ring_w = rw;
        try self.sinks.append(self.a, s);
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

pub fn run(sh: *Shell, p: ast.Pipeline) Err!?u8 {
    if (!supported) return null;
    const a = sh.sa;
    const n = p.commands.len;
    var stages = try a.alloc(Stage, n);
    var argvs = try a.alloc([]const []const u8, n);
    for (p.commands, 0..) |c, i| {
        const s = c.body.simple;
        var list: std.ArrayList([]const u8) = .empty;
        sh.lineno = c.line;
        try expand.words_fields(sh, s.words, &list);
        if (list.items.len == 0) return null;
        argvs[i] = list.items;
        const name = list.items[0];
        const run_fn = registry.lookup(name) orelse return null;
        if (!registry.supports(list.items)) return null;
        if (!@import("exec.zig").util_ok_pub(sh, name, c.redirs)) return null;
        if (sh.funcs.contains(name)) return null;
        stages[i] = .{ .argv = list.items, .run_fn = run_fn, .sh = sh, .group = undefined, .env = undefined, .cwd = undefined };
    }

    var group: Group = .{};
    var b: Build = .{ .sh = sh, .a = a, .group = &group };

    const stdout_default = try b.sink_fd(1, false);
    const stderr_default = try b.sink_fd(2, false);

    const rings = try a.alloc(?*Ring, n - 1);
    for (rings) |*r| r.* = try b.new_ring();

    const Env = struct {
        pairs: []const [2][]const u8,
        fn get(c: ?*const anyopaque, key: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(c.?));
            for (self.pairs) |pr| if (std.mem.eql(u8, pr[0], key)) return pr[1];
            return null;
        }
    };
    var pairs: std.ArrayList([2][]const u8) = .empty;
    var vit = sh.vars.map.iterator();
    while (vit.next()) |e| {
        const v = e.value_ptr.*;
        switch (v.value) {
            .str => |s| try pairs.append(a, .{ v.name, s }),
            else => {},
        }
    }
    var env_ctx: Env = .{ .pairs = pairs.items };
    const env: common.EnvView = .{ .context = &env_ctx, .get_fn = Env.get };
    const cwd = sh.get_scalar("PWD") orelse ".";

    var pipe_out_sinks = try a.alloc(*Sink, n);
    for (0..n) |i| {
        pipe_out_sinks[i] = if (i + 1 < n) try b.sink_ring(rings[i].?) else stdout_default;
    }

    for (p.commands, 0..) |c, i| {
        var st = &stages[i];
        st.group = &group;
        st.env = &env;
        st.cwd = cwd;
        st.in_buf = try a.alloc(u8, 65536);
        st.src = if (i == 0) .{ .fd = 0 } else .{ .ring = rings[i - 1].? };
        var fd1: *Sink = pipe_out_sinks[i];
        var fd2: *Sink = if (i < p.pipe_stderr.len and p.pipe_stderr[i] and i + 1 < n) pipe_out_sinks[i] else stderr_default;
        for (c.redirs) |r| {
            const target_fd: c_int = switch (r.fd) {
                .none => switch (r.op) {
                    .in => 0,
                    else => 1,
                },
                .num => |x| @intCast(x),
                .named => return null,
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
                    const sink = try b.sink_fd(fd, true);
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
                else => return null,
            }
        }
        st.sink_out = fd1;
        st.sink_err = fd2;
    }

    if (sh.opt(.xtrace)) {
        for (stages) |st| try @import("exec.zig").trace_argv(sh, st.argv);
    }

    const fibers = try a.alloc(Fiber, n);
    for (fibers, 0..) |*f, i| {
        f.* = .{ .group = &group, .stage = &stages[i] };
        f.stack = try sh.gpa.alloc(u8, stack_size);
        _ = getcontext(&f.ctx);
        f.ctx.ss_sp = f.stack.ptr;
        f.ctx.ss_size = f.stack.len;
        f.ctx.link = &group.main_ctx;
        makecontext(&f.ctx, &fiber_entry, 0);
    }
    defer for (fibers) |f| sh.gpa.free(f.stack);

    const old_pipe = sys.get_signal(sys.SIGPIPE);
    sys.set_signal(sys.SIGPIPE, sys.SIG_IGN);
    defer sys.set_signal(sys.SIGPIPE, old_pipe);

    const saved_active = active_group;
    active_group = &group;
    defer active_group = saved_active;

    var idle_passes: u32 = 0;
    while (true) {
        var alive = false;
        var progressed = false;
        for (fibers) |*f| {
            if (f.done) continue;
            alive = true;
            const mark = group.progress;
            group.running = f;
            _ = swapcontext(&group.main_ctx, &f.ctx);
            group.running = null;
            if (f.done or group.progress != mark) progressed = true;
        }
        if (!alive) break;
        if (progressed) idle_passes = 0 else {
            idle_passes += 1;
            if (idle_passes > 4) group.aborted = true;
        }
    }
    for (b.opened.items) |fd| _ = sys.close(fd);

    const sts = try a.alloc(u8, n);
    for (stages, 0..) |st, i| sts[i] = st.status;
    @import("exec.zig").set_pipestatus_pub(sh, sts);
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

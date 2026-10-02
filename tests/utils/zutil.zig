const std = @import("std");
const registry = @import("registry");
const common = registry.common_mod;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var argv_list: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |a| try argv_list.append(init.arena.allocator(), a);
    var argv = argv_list.items;
    var check_only = false;
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "--supports")) {
        check_only = true;
        argv = argv[1..];
    }
    if (argv.len == 0) std.process.exit(2);

    const EnvCtx = struct {
        map: *const std.process.Environ.Map,
        fn get(c: ?*const anyopaque, key: []const u8) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(c.?));
            return self.map.get(key);
        }
    };
    const env_ctx: EnvCtx = .{ .map = init.environ_map };
    const env: common.EnvView = .{ .context = &env_ctx, .get_fn = EnvCtx.get };

    if (check_only) {
        std.process.exit(if (registry.supportsEnv(&env, argv)) 0 else 1);
    }

    const run_fn = registry.lookup(argv[0]) orelse std.process.exit(127);

    const inbuf_len: usize = if (init.environ_map.get("ZUTIL_INBUF")) |s| (std.fmt.parseInt(usize, s, 10) catch 65536) else 65536;
    const in_buf = try alloc.alloc(u8, inbuf_len);
    const out_buf = try alloc.alloc(u8, 65536);
    const err_buf = try alloc.alloc(u8, 4096);
    var in_r = std.Io.File.stdin().readerStreaming(io, in_buf);
    var out_w = std.Io.File.stdout().writerStreaming(io, out_buf);
    var err_w = std.Io.File.stderr().writerStreaming(io, err_buf);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    var ctx: common.Ctx = .{ .alloc = alloc, .io = io, .cwd = cwd_buf[0..cwd_len], .env = &env };
    const status = run_fn(&ctx, argv, .{ .in = &in_r.interface, .out = &out_w.interface, .err = &err_w.interface });
    out_w.interface.flush() catch {};
    err_w.interface.flush() catch {};
    std.process.exit(status);
}

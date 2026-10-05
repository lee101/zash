const std = @import("std");
const zash = @import("zash");

const interp = zash.interp;
const sys = interp.sys;

const usage = "usage: zash [--dump-ast] [-n] [-eux...] [-o option] [-O shopt] (-c command [name [arg...]] | [script [arg...]])\n";

fn die(msg: []const u8, code: u8) u8 {
    _ = sys.write_all(2, msg);
    return code;
}

fn read_all_fd(a: std.mem.Allocator, fd: c_int) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = sys.read_some(fd, &chunk);
        if (n <= 0) break;
        try buf.appendSlice(a, chunk[0..@intCast(n)]);
    }
    return buf.items;
}

extern var environ: [*:null]?[*:0]u8;

comptime {
    if (!@import("builtin").is_test) @export(&main, .{ .name = "main" });
}

pub fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var n: usize = 0;
    while (environ[n] != null) n += 1;
    const env: []const ?[*:0]const u8 = @ptrCast(environ[0..n]);
    return real_main(@intCast(argc), argv, env);
}

fn real_main(argc: usize, argv_in: [*][*:0]u8, env_ptrs_in: []const ?[*:0]const u8) u8 {
    const gpa = interp.alloc.allocator_instance;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const args = arena.alloc([:0]const u8, argc) catch return 1;
    for (args, 0..) |*slot, k| slot.* = std.mem.span(argv_in[k]);
    const io = std.Io.Threaded.global_single_threaded.io();
    const sh = interp.Shell.init(gpa, io) catch return 1;

    var dump_ast = false;
    var parse_only = false;
    var command: ?[]const u8 = null;
    var script: ?[]const u8 = null;
    var read_stdin = false;
    var interactive = false;
    var i: usize = 1;
    var set_flags: std.ArrayList([]const u8) = .empty;
    var shopt_args: std.ArrayList([2][]const u8) = .empty;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            _ = sys.write_all(1, "zash " ++ zash.version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, a, "--dump-ast")) {
            dump_ast = true;
        } else if (std.mem.eql(u8, a, "--norc") or std.mem.eql(u8, a, "--noprofile") or std.mem.eql(u8, a, "--login") or std.mem.eql(u8, a, "--posix") or std.mem.eql(u8, a, "--noediting") or std.mem.eql(u8, a, "--restricted")) {} else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "-")) {
            read_stdin = true;
            i += 1;
            break;
        } else if (a.len > 1 and (a[0] == '-' or a[0] == '+')) {
            const on = a[0] == '-';
            var j: usize = 1;
            while (j < a.len) : (j += 1) {
                const c = a[j];
                switch (c) {
                    'c' => {
                        if (on) {
                            i += 1;
                            if (i >= args.len) return die("zash: -c: option requires an argument\n", 2);
                            command = args[i];
                        }
                    },
                    's' => read_stdin = true,
                    'i' => interactive = true,
                    'l' => {},
                    'n' => parse_only = true,
                    'o' => {
                        i += 1;
                        if (i >= args.len) return die("zash: -o: option requires an argument\n", 2);
                        set_flags.append(arena, std.fmt.allocPrint(arena, "{c}o", .{a[0]}) catch return 1) catch return 1;
                        set_flags.append(arena, args[i]) catch return 1;
                    },
                    'O' => {
                        i += 1;
                        if (i >= args.len) return die("zash: -O: option requires an argument\n", 2);
                        shopt_args.append(arena, .{ if (on) "-s" else "-u", args[i] }) catch return 1;
                    },
                    else => {
                        set_flags.append(arena, std.fmt.allocPrint(arena, "{c}{c}", .{ a[0], c }) catch return 1) catch return 1;
                    },
                }
            }
        } else break;
    }
    const rest = args[i..];

    const env_ptrs = env_ptrs_in;

    var script_name: []const u8 = "zash";
    var pos_args: []const [:0]const u8 = rest;
    var source: []const u8 = "";
    if (command) |c| {
        source = c;
        if (rest.len > 0) {
            script_name = rest[0];
            pos_args = rest[1..];
        } else pos_args = rest;
    } else if (!read_stdin and rest.len > 0) {
        script = rest[0];
        script_name = rest[0];
        pos_args = rest[1..];
        source = std.Io.Dir.cwd().readFileAlloc(io, rest[0], arena, .limited(1 << 28)) catch {
            const msg = std.fmt.allocPrint(arena, "zash: {s}: No such file or directory\n", .{rest[0]}) catch return 127;
            return die(msg, 127);
        };
    } else {
        read_stdin = true;
        if (interactive or sys.isatty(0) == 1) {
            interactive = true;
        } else source = read_all_fd(arena, 0) catch return 1;
    }

    interp.setup(sh, env_ptrs, script_name) catch return 1;
    sh.dash_c = command != null;
    interp.exec.set_last_arg(sh, args[0]);
    if (command != null) sh.assign_scalar("BASH_EXECUTION_STRING", source, false) catch {};
    sh.interactive = interactive;
    sh.set_pos_args(pos_args) catch return 1;
    {
        const set_b = interp.builtins.lookup("set").?;
        var k: usize = 0;
        while (k < set_flags.items.len) {
            if (std.mem.eql(u8, set_flags.items[k][1..], "o")) {
                const argv = [_][]const u8{ "set", set_flags.items[k], set_flags.items[k + 1] };
                _ = set_b.run(sh, &argv) catch {};
                k += 2;
            } else {
                const argv = [_][]const u8{ "set", set_flags.items[k] };
                _ = set_b.run(sh, &argv) catch {};
                k += 1;
            }
        }
        const sb = interp.builtins.lookup("shopt").?;
        for (shopt_args.items) |sa| {
            const argv = [_][]const u8{ "shopt", sa[0], sa[1] };
            _ = sb.run(sh, &argv) catch {};
        }
    }

    if (dump_ast or parse_only) {
        switch (zash.parser.parse(arena, source, .{})) {
            .err => |e| {
                var aw = std.Io.Writer.Allocating.init(arena);
                e.write(&aw.writer, if (command != null) "zash: -c" else script_name) catch {};
                _ = sys.write_all(2, aw.written());
                return 2;
            },
            .ok => |list| {
                if (dump_ast) {
                    var aw = std.Io.Writer.Allocating.init(arena);
                    zash.ast_dump.dump_list(&aw.writer, list) catch {};
                    aw.writer.writeByte('\n') catch {};
                    _ = sys.write_all(1, aw.written());
                }
                return 0;
            },
        }
    }

    if (command != null) exec_fallback(arena, source, args, argv_in);
    if (interactive and command == null and script == null) return interp.run_interactive(sh);
    const prefix: []const u8 = if (command != null) (std.fmt.allocPrint(arena, "{s}: -c", .{script_name}) catch script_name) else script_name;
    const status = interp.run_script(sh, source, prefix);
    return status;
}

fn exec_fallback(arena: std.mem.Allocator, source: []const u8, args: []const [:0]const u8, argv_in: [*][*:0]u8) void {
    var fb: ?[*:0]const u8 = null;
    var k: usize = 0;
    while (environ[k]) |e| : (k += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "ZASH_BASH_FALLBACK=") and s.len > 19) fb = e + 19;
    }
    const path = fb orelse return;
    const bail = switch (zash.parser.parse(arena, source, .{})) {
        .err => true,
        .ok => |list| blk: {
            for (list.items) |it| if (it.background) break :blk true;
            break :blk false;
        },
    };
    if (!bail) return;
    const out = arena.alloc(?[*:0]const u8, args.len + 1) catch return;
    out[0] = path;
    for (1..args.len) |j| out[j] = argv_in[j];
    out[args.len] = null;
    _ = interp.sys.execve(path, @ptrCast(out.ptr), @ptrCast(environ));
}

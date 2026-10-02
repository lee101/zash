const std = @import("std");
const zash = @import("zash");

const usage = "usage: zash [--dump-ast] [-n] (-c command | script)\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &err_buf);
    const status = run(io, arena, args[1..], &out.interface, &err.interface);
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(status);
}

fn run(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) u8 {
    var dump_ast = false;
    var parse_only = false;
    var command: ?[]const u8 = null;
    var script: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            out.print("zash {s}\n", .{zash.version}) catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--dump-ast")) {
            dump_ast = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            parse_only = true;
        } else if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= args.len) {
                err.writeAll("zash: -c: option requires an argument\n") catch {};
                return 2;
            }
            command = args[i];
        } else if (a.len > 0 and a[0] == '-' and a.len > 1) {
            err.print("zash: {s}: invalid option\n{s}", .{ a, usage }) catch {};
            return 2;
        } else {
            script = a;
            break;
        }
    }

    var prefix: []const u8 = "zash: -c";
    var source: []const u8 = undefined;
    if (command) |c| {
        source = c;
    } else if (script) |path| {
        prefix = path;
        source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 28)) catch {
            err.print("zash: {s}: No such file or directory\n", .{path}) catch {};
            return 127;
        };
    } else {
        err.writeAll(usage) catch {};
        return 2;
    }

    switch (zash.parser.parse(arena, source, .{})) {
        .err => |e| {
            e.write(err, prefix) catch {};
            return 2;
        },
        .ok => |list| {
            if (dump_ast) {
                zash.ast_dump.dump_list(out, list) catch {};
                out.writeByte('\n') catch {};
                return 0;
            }
            if (parse_only) return 0;
            err.writeAll("zash: execution is not implemented yet\n") catch {};
            return 1;
        },
    }
}

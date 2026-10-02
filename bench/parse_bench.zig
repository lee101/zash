const std = @import("std");
const zash = @import("zash");

const samples = [_][]const u8{
    "ls -la",
    "rg -n 'foo.*bar' src | head -n 20",
    "cat a.txt | sort | uniq -c | sort -rn | head -n 5",
    "if [ -f x ]; then echo yes; else echo no; fi",
    "for f in *.c; do gcc -c \"$f\" -o \"${f%.c}.o\" || exit 1; done",
    "git log --oneline -n 10 2>/dev/null | cut -d' ' -f1 | tr -d '\\n' > /tmp/out",
    "x=$(grep -c pattern file) && echo \"count: $x\" || echo none",
    "case \"$1\" in start) run;; stop|halt) stop;; *) usage >&2; exit 2;; esac",
    "cat <<EOF\nline $a\nline ${b:-c}\nEOF",
    "[[ $a =~ ^[0-9]+$ && -n ${b} ]] && echo $((a * 2 + 1))",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const iters: usize = 200000;
    var total_ns: u128 = 0;
    var total_bytes: usize = 0;
    for (samples) |src| {
        var sink: usize = 0;
        const t0 = std.Io.Timestamp.now(io, .awake);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            _ = arena.reset(.retain_capacity);
            switch (zash.parser.parse(arena.allocator(), src, .{})) {
                .ok => |l| sink += l.items.len,
                .err => sink += 1,
            }
        }
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ns: u128 = @intCast(t0.durationTo(t1).nanoseconds);
        total_ns += ns;
        total_bytes += src.len * iters;
        try w.print("{d:>6} ns  {d:>4} B  {s}\n", .{ @as(u64, @intCast(ns / iters)), src.len, src[0..@min(src.len, 50)] });
        std.mem.doNotOptimizeAway(sink);
    }
    const mbps = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(total_ns)) / 1e9) / 1e6;
    try w.print("throughput {d:.1} MB/s\n", .{mbps});
    try w.flush();
}

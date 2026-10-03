const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const page: usize = 4096;
const bigpage: usize = 64 * 1024;
const min_shift = 4;
const max_shift = 16;
const class_count = max_shift - min_shift + 1;
const grow_chunk: usize = 1 << 20;

var next: [class_count]usize = @splat(0);
var end: [class_count]usize = @splat(0);
var frees: [class_count]usize = @splat(0);
var pool_cur: usize = 0;
var pool_end: usize = 0;

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub const allocator_instance: Allocator = .{ .ptr = undefined, .vtable = &vtable };

fn map(len: usize) usize {
    const r = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return 0;
    return r;
}

fn take_bigpage() usize {
    if (pool_cur == pool_end) {
        const base = map(grow_chunk + bigpage);
        if (base == 0) return 0;
        pool_cur = std.mem.alignForward(usize, base, bigpage);
        pool_end = pool_cur + grow_chunk;
    }
    const r = pool_cur;
    pool_cur += bigpage;
    return r;
}

fn class_of(len: usize, alignment: Alignment) ?usize {
    const need = @max(len, alignment.toByteUnits(), 1);
    if (need > (1 << max_shift)) return null;
    const shift: usize = if (need <= (1 << min_shift)) min_shift else std.math.log2_int_ceil(usize, need);
    return shift - min_shift;
}

fn large_len(len: usize) usize {
    return std.mem.alignForward(usize, len, page);
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    if (class_of(len, alignment)) |c| {
        const f = frees[c];
        if (f != 0) {
            const node: *usize = @ptrFromInt(f);
            frees[c] = node.*;
            return @ptrFromInt(f);
        }
        const size = @as(usize, 1) << @intCast(c + min_shift);
        if (next[c] + size > end[c] or next[c] == 0) {
            const p = take_bigpage();
            if (p == 0) return null;
            next[c] = p;
            end[c] = p + bigpage;
        }
        const r = next[c];
        next[c] += size;
        return @ptrFromInt(r);
    }
    if (alignment.toByteUnits() > page) return null;
    const r = map(large_len(len));
    if (r == 0) return null;
    return @ptrFromInt(r);
}

fn resize(_: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    if (class_of(buf.len, alignment)) |c| {
        const nc = class_of(new_len, alignment) orelse return false;
        return c == nc;
    }
    if (class_of(new_len, alignment) != null) return false;
    const old = large_len(buf.len);
    const new = large_len(new_len);
    if (old == new) return true;
    if (new < old) {
        _ = linux.munmap(@ptrFromInt(@intFromPtr(buf.ptr) + new), old - new);
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (class_of(buf.len, alignment) != null or class_of(new_len, alignment) != null) {
        return if (resize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
    }
    const old = large_len(buf.len);
    const new = large_len(new_len);
    if (old == new) return buf.ptr;
    const r = linux.mremap(buf.ptr, old, new, .{ .MAYMOVE = true }, null);
    if (linux.errno(r) != .SUCCESS) return null;
    return @ptrFromInt(r);
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, _: usize) void {
    if (class_of(buf.len, alignment)) |c| {
        const node: *usize = @ptrCast(@alignCast(buf.ptr));
        node.* = frees[c];
        frees[c] = @intFromPtr(buf.ptr);
        return;
    }
    _ = linux.munmap(buf.ptr, large_len(buf.len));
}

test "allocator basics" {
    const a = allocator_instance;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    var i: usize = 0;
    while (i < 300000) : (i += 1) try list.append(a, @truncate(i));
    try std.testing.expectEqual(@as(u8, 0), list.items[256]);
    const s = try a.alloc(u64, 100);
    a.free(s);
    const s2 = try a.alloc(u64, 100);
    try std.testing.expectEqual(@intFromPtr(s.ptr), @intFromPtr(s2.ptr));
    a.free(s2);
    const big = try a.alignedAlloc(u8, .fromByteUnits(4096), 100);
    try std.testing.expect(@intFromPtr(big.ptr) % 4096 == 0);
    a.free(big);
}

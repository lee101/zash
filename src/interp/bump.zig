const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Bump = struct {
    backing: Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    cur: usize = 0,
    off: usize = 0,
    last_ptr: usize = 0,

    pub const Mark = struct { cur: usize, off: usize };
    const min_chunk = 64 * 1024;

    pub fn init(backing: Allocator) Bump {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *Bump) void {
        for (self.chunks.items) |c| self.backing.free(c);
        self.chunks.deinit(self.backing);
    }

    pub fn allocator(self: *Bump) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn mark(self: *Bump) Mark {
        return .{ .cur = self.cur, .off = self.off };
    }

    pub fn release(self: *Bump, m: Mark) void {
        self.cur = m.cur;
        self.off = m.off;
        self.last_ptr = 0;
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Bump = @ptrCast(@alignCast(ctx));
        const al = alignment.toByteUnits();
        while (true) {
            if (self.cur < self.chunks.items.len) {
                const chunk = self.chunks.items[self.cur];
                const base = @intFromPtr(chunk.ptr);
                const start = std.mem.alignForward(usize, base + self.off, al) - base;
                if (start + len <= chunk.len) {
                    self.off = start + len;
                    self.last_ptr = base + start;
                    return chunk.ptr + start;
                }
                if (self.cur + 1 < self.chunks.items.len and self.chunks.items[self.cur + 1].len >= len + al) {
                    self.cur += 1;
                    self.off = 0;
                    continue;
                }
                if (self.cur + 1 < self.chunks.items.len) {
                    const bigger = self.backing.alloc(u8, @max(min_chunk, len + al)) catch return null;
                    self.backing.free(self.chunks.items[self.cur + 1]);
                    self.chunks.items[self.cur + 1] = bigger;
                    self.cur += 1;
                    self.off = 0;
                    continue;
                }
            }
            const size = @max(min_chunk, len + al);
            const c = self.backing.alloc(u8, size) catch return null;
            self.chunks.append(self.backing, c) catch {
                self.backing.free(c);
                return null;
            };
            if (self.chunks.items.len > 1) self.cur = self.chunks.items.len - 1;
            self.off = 0;
        }
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const self: *Bump = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            if (self.last_ptr == @intFromPtr(memory.ptr)) self.off -= memory.len - new_len;
            return true;
        }
        if (self.last_ptr != @intFromPtr(memory.ptr)) return false;
        const chunk = self.chunks.items[self.cur];
        const base = @intFromPtr(chunk.ptr);
        const start = @intFromPtr(memory.ptr) - base;
        if (start + new_len > chunk.len) return false;
        self.off = start + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, new_len, ra)) return memory.ptr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Bump = @ptrCast(@alignCast(ctx));
        if (self.last_ptr == @intFromPtr(memory.ptr)) {
            self.off -= memory.len;
            self.last_ptr = 0;
        }
    }
};

test "bump mark release" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    const m = b.mark();
    var list: std.ArrayList(u8) = .empty;
    for (0..200000) |i| try list.append(a, @intCast(i & 0xff));
    try std.testing.expectEqual(@as(usize, 200000), list.items.len);
    b.release(m);
    const s = try a.alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 10), s.len);
}

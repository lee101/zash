const std = @import("std");
const Allocator = std.mem.Allocator;
const sets = @import("unicode_sets.zig");

pub const max_cp: u32 = 0x10ffff;

pub const CpSet = struct {
    r: std.ArrayList([2]u32) = .empty,

    pub fn deinit(self: *CpSet, a: Allocator) void {
        self.r.deinit(a);
    }

    pub fn add(self: *CpSet, a: Allocator, lo: u32, hi: u32) !void {
        try self.r.append(a, .{ lo, hi });
    }

    pub fn addTable(self: *CpSet, a: Allocator, table: []const [2]u32) !void {
        try self.r.appendSlice(a, table);
    }

    pub fn normalize(self: *CpSet) void {
        const items = self.r.items;
        std.mem.sort([2]u32, items, {}, struct {
            fn lt(_: void, x: [2]u32, y: [2]u32) bool {
                return x[0] < y[0];
            }
        }.lt);
        var w: usize = 0;
        for (items) |e| {
            if (w > 0 and e[0] <= items[w - 1][1] +| 1) {
                if (e[1] > items[w - 1][1]) items[w - 1][1] = e[1];
            } else {
                items[w] = e;
                w += 1;
            }
        }
        self.r.shrinkRetainingCapacity(w);
    }

    pub fn contains(self: *const CpSet, cp: u32) bool {
        var lo: usize = 0;
        var hi: usize = self.r.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.r.items[mid];
            if (cp < e[0]) {
                hi = mid;
            } else if (cp > e[1]) {
                lo = mid + 1;
            } else return true;
        }
        return false;
    }

    pub fn negate(self: *CpSet, a: Allocator, max: u32) !void {
        self.normalize();
        var out: std.ArrayList([2]u32) = .empty;
        errdefer out.deinit(a);
        var next: u32 = 0;
        for (self.r.items) |e| {
            if (e[0] > next) try out.append(a, .{ next, e[0] - 1 });
            next = e[1] +| 1;
            if (next > max) break;
        }
        if (next <= max) try out.append(a, .{ next, max });
        self.r.deinit(a);
        self.r = out;
    }

    pub fn remove(self: *CpSet, a: Allocator, cp: u32) !void {
        self.normalize();
        var out: std.ArrayList([2]u32) = .empty;
        errdefer out.deinit(a);
        for (self.r.items) |e| {
            if (cp < e[0] or cp > e[1]) {
                try out.append(a, e);
            } else {
                if (e[0] < cp) try out.append(a, .{ e[0], cp - 1 });
                if (cp < e[1]) try out.append(a, .{ cp + 1, e[1] });
            }
        }
        self.r.deinit(a);
        self.r = out;
    }

    pub fn foldClosure(self: *CpSet, a: Allocator, classes: []const u32) !void {
        self.normalize();
        var i: usize = 0;
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(a);
        while (i < classes.len) {
            var j = i;
            while (classes[j] != 0) j += 1;
            const members = classes[i..j];
            var any = false;
            for (members) |m| {
                if (self.contains(m)) {
                    any = true;
                    break;
                }
            }
            if (any) try extra.appendSlice(a, members);
            i = j + 1;
        }
        for (extra.items) |m| try self.r.append(a, .{ m, m });
        self.normalize();
    }

    pub fn isAsciiOnly(self: *const CpSet) bool {
        return self.r.items.len == 0 or self.r.items[self.r.items.len - 1][1] < 0x80;
    }
};

pub const Seq = struct {
    len: u3,
    r: [4][2]u8,
};

fn encode(cp: u32, out: *[4]u8) u3 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xc0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3f));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xe0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        out[2] = @intCast(0x80 | (cp & 0x3f));
        return 3;
    }
    out[0] = @intCast(0xf0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3f));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3f));
    out[3] = @intCast(0x80 | (cp & 0x3f));
    return 4;
}

pub fn utf8Sequences(a: Allocator, lo_in: u32, hi_in: u32, out: *std.ArrayList(Seq)) !void {
    var stack: std.ArrayList([2]u32) = .empty;
    defer stack.deinit(a);
    try stack.append(a, .{ lo_in, hi_in });
    while (stack.pop()) |rg| {
        var lo = rg[0];
        var hi = rg[1];
        if (lo > hi) continue;
        if (lo <= 0xdfff and hi >= 0xd800) {
            if (lo < 0xd800) try stack.append(a, .{ lo, 0xd7ff });
            if (hi > 0xdfff) try stack.append(a, .{ 0xe000, hi });
            continue;
        }
        const bounds = [_]u32{ 0x7f, 0x7ff, 0xffff };
        var split = false;
        for (bounds) |b| {
            if (lo <= b and b < hi) {
                try stack.append(a, .{ b + 1, hi });
                try stack.append(a, .{ lo, b });
                split = true;
                break;
            }
        }
        if (split) continue;
        if (hi < 0x80) {
            try out.append(a, .{ .len = 1, .r = .{ .{ @intCast(lo), @intCast(hi) }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } } });
            continue;
        }
        var i: u5 = 1;
        var did = false;
        while (i < 4) : (i += 1) {
            const m: u32 = (@as(u32, 1) << (6 * i)) - 1;
            if ((lo & ~m) != (hi & ~m)) {
                if ((lo & m) != 0) {
                    try stack.append(a, .{ (lo | m) + 1, hi });
                    try stack.append(a, .{ lo, lo | m });
                    did = true;
                    break;
                }
                if ((hi & m) != m) {
                    try stack.append(a, .{ hi & ~m, hi });
                    try stack.append(a, .{ lo, (hi & ~m) - 1 });
                    did = true;
                    break;
                }
            }
        }
        if (did) continue;
        var e1: [4]u8 = undefined;
        var e2: [4]u8 = undefined;
        const n = encode(lo, &e1);
        _ = encode(hi, &e2);
        var seq: Seq = .{ .len = n, .r = undefined };
        for (0..n) |k| seq.r[k] = .{ e1[k], e2[k] };
        try out.append(a, seq);
        lo = 0;
        hi = 0;
    }
    const slice = out.items;
    std.mem.sort(Seq, slice, {}, struct {
        fn lt(_: void, x: Seq, y: Seq) bool {
            var k: usize = 0;
            while (k < x.len and k < y.len) : (k += 1) {
                if (x.r[k][0] != y.r[k][0]) return x.r[k][0] < y.r[k][0];
                if (x.r[k][1] != y.r[k][1]) return x.r[k][1] < y.r[k][1];
            }
            return x.len < y.len;
        }
    }.lt);
}

pub fn inTable(table: []const [2]u32, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < table[mid][0]) {
            hi = mid;
        } else if (cp > table[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub const Charset = enum { glibc, rust };

pub fn classTable(cs: Charset, name: []const u8) ?[]const [2]u32 {
    switch (cs) {
        .glibc => {
            if (std.mem.eql(u8, name, "alpha")) return &sets.glibc_alpha_ranges;
            if (std.mem.eql(u8, name, "alnum")) return &sets.glibc_alnum_ranges;
            if (std.mem.eql(u8, name, "upper")) return &sets.glibc_upper_ranges;
            if (std.mem.eql(u8, name, "lower")) return &sets.glibc_lower_ranges;
            if (std.mem.eql(u8, name, "punct")) return &sets.glibc_punct_ranges;
            if (std.mem.eql(u8, name, "space")) return &sets.glibc_space_ranges;
            if (std.mem.eql(u8, name, "print")) return &sets.glibc_print_ranges;
            if (std.mem.eql(u8, name, "graph")) return &sets.glibc_graph_ranges;
            if (std.mem.eql(u8, name, "cntrl")) return &sets.glibc_cntrl_ranges;
            if (std.mem.eql(u8, name, "blank")) return &sets.glibc_blank_ranges;
            if (std.mem.eql(u8, name, "digit")) return &sets.glibc_digit_ranges;
            if (std.mem.eql(u8, name, "xdigit")) return &sets.glibc_xdigit_ranges;
            if (std.mem.eql(u8, name, "word")) return &sets.glibc_word_ranges;
        },
        .rust => {
            if (std.mem.eql(u8, name, "word")) return &sets.rust_word_ranges;
            if (std.mem.eql(u8, name, "digit")) return &sets.rust_digit_ranges;
            if (std.mem.eql(u8, name, "space")) return &sets.rust_space_ranges;
        },
    }
    return null;
}

pub fn foldClasses(cs: Charset) []const u32 {
    return switch (cs) {
        .glibc => &sets.glibc_fold,
        .rust => &sets.rust_fold,
    };
}

test "utf8 sequences cover ranges" {
    const a = std.testing.allocator;
    var out: std.ArrayList(Seq) = .empty;
    defer out.deinit(a);
    try utf8Sequences(a, 0x80, 0x10ffff, &out);
    try std.testing.expect(out.items.len > 5);
    var any: std.ArrayList(Seq) = .empty;
    defer any.deinit(a);
    try utf8Sequences(a, 0, 0x7f, &any);
    try std.testing.expectEqual(@as(usize, 1), any.items.len);
}

test "cpset ops" {
    const a = std.testing.allocator;
    var s: CpSet = .{};
    defer s.deinit(a);
    try s.add(a, 'a', 'c');
    try s.add(a, 'b', 'f');
    s.normalize();
    try std.testing.expectEqual(@as(usize, 1), s.r.items.len);
    try s.negate(a, 0x10ffff);
    try std.testing.expect(s.contains('a') == false and s.contains('g') and s.contains(0));
    var f: CpSet = .{};
    defer f.deinit(a);
    try f.add(a, 'k', 'k');
    try f.foldClosure(a, foldClasses(.rust));
    try std.testing.expect(f.contains('K') and f.contains(0x212a));
    var g: CpSet = .{};
    defer g.deinit(a);
    try g.add(a, 's', 's');
    try g.foldClosure(a, foldClasses(.glibc));
    try std.testing.expect(g.contains('S') and g.contains(0x17f));
}

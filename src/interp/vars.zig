const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Flags = packed struct {
    exported: bool = false,
    readonly: bool = false,
    integer: bool = false,
    nameref: bool = false,
    lower: bool = false,
    upper: bool = false,
    capital: bool = false,
    trace: bool = false,
    local: bool = false,
};

pub const Elem = struct { idx: i64, val: []u8 };

pub const Indexed = struct {
    items: std.ArrayList(Elem) = .empty,

    pub fn deinit(self: *Indexed, a: Allocator) void {
        for (self.items.items) |e| a.free(e.val);
        self.items.deinit(a);
    }

    pub fn find(self: *const Indexed, idx: i64) usize {
        const items = self.items.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].idx < idx) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn get(self: *const Indexed, idx: i64) ?[]const u8 {
        const i = self.find(idx);
        if (i < self.items.items.len and self.items.items[i].idx == idx) return self.items.items[i].val;
        return null;
    }

    pub fn set(self: *Indexed, a: Allocator, idx: i64, val: []const u8) Allocator.Error!void {
        const copy = try a.dupe(u8, val);
        errdefer a.free(copy);
        const i = self.find(idx);
        if (i < self.items.items.len and self.items.items[i].idx == idx) {
            a.free(self.items.items[i].val);
            self.items.items[i].val = copy;
            return;
        }
        try self.items.insert(a, i, .{ .idx = idx, .val = copy });
    }

    pub fn remove(self: *Indexed, a: Allocator, idx: i64) bool {
        const i = self.find(idx);
        if (i < self.items.items.len and self.items.items[i].idx == idx) {
            a.free(self.items.items[i].val);
            _ = self.items.orderedRemove(i);
            return true;
        }
        return false;
    }

    pub fn max_index(self: *const Indexed) i64 {
        if (self.items.items.len == 0) return -1;
        return self.items.items[self.items.items.len - 1].idx;
    }

    pub fn clear(self: *Indexed, a: Allocator) void {
        for (self.items.items) |e| a.free(e.val);
        self.items.clearRetainingCapacity();
    }
};

pub fn bash_hash(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |c| {
        h *%= 16777619;
        h ^= c;
    }
    return h;
}

pub const Assoc = struct {
    map: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    order: ?[]u32 = null,

    fn invalidate(self: *Assoc, a: Allocator) void {
        if (self.order) |o| a.free(o);
        self.order = null;
    }

    const SortCtx = struct {
        keys: []const []const u8,
        nb: u32,
        fn less(self: SortCtx, x: u32, y: u32) bool {
            const bx = bash_hash(self.keys[x]) & (self.nb - 1);
            const by = bash_hash(self.keys[y]) & (self.nb - 1);
            if (bx != by) return bx < by;
            return x > y;
        }
    };

    pub fn ordered(self: *Assoc, a: Allocator) Allocator.Error![]const u32 {
        if (self.order) |o| return o;
        const n = self.map.count();
        const o = try a.alloc(u32, n);
        for (o, 0..) |*e, i| e.* = @intCast(i);
        var nb: u32 = 1024;
        while (n >= nb * 2) nb *= 2;
        std.mem.sort(u32, o, SortCtx{ .keys = self.map.keys(), .nb = nb }, SortCtx.less);
        self.order = o;
        return o;
    }

    pub fn deinit(self: *Assoc, a: Allocator) void {
        self.invalidate(a);
        var it = self.map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.map.deinit(a);
    }

    pub fn get(self: *const Assoc, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn set(self: *Assoc, a: Allocator, key: []const u8, val: []const u8) Allocator.Error!void {
        const copy = try a.dupe(u8, val);
        errdefer a.free(copy);
        if (self.map.getPtr(key)) |p| {
            a.free(p.*);
            p.* = copy;
            return;
        }
        const k = try a.dupe(u8, key);
        errdefer a.free(k);
        try self.map.put(a, k, copy);
        self.invalidate(a);
    }

    pub fn remove(self: *Assoc, a: Allocator, key: []const u8) bool {
        if (self.map.fetchOrderedRemove(key)) |kv| {
            a.free(kv.key);
            a.free(kv.value);
            self.invalidate(a);
            return true;
        }
        return false;
    }

    pub fn clear(self: *Assoc, a: Allocator) void {
        self.invalidate(a);
        var it = self.map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }
};

pub const Value = union(enum) {
    none,
    str: []u8,
    indexed: Indexed,
    assoc: Assoc,
};

pub const Special = enum {
    none,
    random,
    lineno,
    seconds,
    bashpid,
    epochseconds,
    epochrealtime,
    funcname,
    bash_source,
    bash_lineno,
    srandom,
    bash_argc,
    bash_argv,
    dirstack,
    groups,
    histcmd,
    comp_words,
};

pub const Var = struct {
    name: []const u8,
    value: Value = .none,
    flags: Flags = .{},
    special: Special = .none,
    depth: u32 = 0,
    declared_array: u2 = 0,
    array_set: bool = false,

    pub fn is_array(self: *const Var) bool {
        return self.value == .indexed or self.value == .assoc;
    }

    pub fn is_set_or_declared(self: *const Var) bool {
        return self.value != .none or self.special != .none or self.flags.exported or self.flags.readonly or self.flags.integer;
    }

    pub fn is_set(self: *const Var) bool {
        return switch (self.value) {
            .none => false,
            .str => true,
            .indexed => |ix| ix.items.items.len > 0,
            .assoc => |m| m.map.count() > 0,
        };
    }
};

pub const Vars = struct {
    map: std.StringHashMapUnmanaged(*Var) = .empty,

    pub fn get(self: *const Vars, name: []const u8) ?*Var {
        return self.map.get(name);
    }

    pub fn deinit_value(a: Allocator, v: *Var) void {
        switch (v.value) {
            .none => {},
            .str => |s| a.free(s),
            .indexed => |*ix| ix.deinit(a),
            .assoc => |*m| m.deinit(a),
        }
        v.value = .none;
    }

    pub fn create(self: *Vars, a: Allocator, name: []const u8) Allocator.Error!*Var {
        const owned = try a.dupe(u8, name);
        errdefer a.free(owned);
        const v = try a.create(Var);
        errdefer a.destroy(v);
        v.* = .{ .name = owned };
        try self.map.put(a, owned, v);
        return v;
    }

    pub fn get_or_create(self: *Vars, a: Allocator, name: []const u8) Allocator.Error!*Var {
        if (self.map.get(name)) |v| return v;
        return self.create(a, name);
    }

    pub fn detach(self: *Vars, name: []const u8) ?*Var {
        if (self.map.fetchRemove(name)) |kv| return kv.value;
        return null;
    }

    pub fn attach(self: *Vars, a: Allocator, v: *Var) Allocator.Error!void {
        try self.map.put(a, v.name, v);
    }

    pub fn destroy(a: Allocator, v: *Var) void {
        deinit_value(a, v);
        a.free(v.name);
        a.destroy(v);
    }
};

test "indexed sparse" {
    const a = std.testing.allocator;
    var ix: Indexed = .{};
    defer ix.deinit(a);
    try ix.set(a, 5, "five");
    try ix.set(a, 1, "one");
    try ix.set(a, 5, "FIVE");
    try std.testing.expectEqualStrings("FIVE", ix.get(5).?);
    try std.testing.expectEqual(@as(i64, 5), ix.max_index());
    try std.testing.expect(ix.remove(a, 1));
    try std.testing.expect(ix.get(1) == null);
}

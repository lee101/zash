const std = @import("std");
const sys = @import("sys.zig");
const pattern = @import("pattern.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Allocator = std.mem.Allocator;

const Entry = struct { name: []const u8, is_dir: bool };

fn split_components(a: Allocator, pat: []const u8, list: *std.ArrayList([]const u8)) Allocator.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
            continue;
        }
        if (pat[i] == '/') {
            try list.append(a, pat[start..i]);
            start = i + 1;
        }
    }
    try list.append(a, pat[start..]);
}

fn join(a: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (base.len == 0) return a.dupe(u8, name);
    if (base[base.len - 1] == '/') return std.mem.concat(a, u8, &.{ base, name });
    return std.mem.concat(a, u8, &.{ base, "/", name });
}

fn read_dir(a: Allocator, path: []const u8, entries: *std.ArrayList(Entry)) Allocator.Error!bool {
    var buf: [4096]u8 = undefined;
    const z = sys.cstr(&buf, if (path.len == 0) "." else path) orelse return false;
    const d = std.c.opendir(z) orelse return false;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |e| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.name)), 0);
        var is_dir = e.type == std.c.DT.DIR;
        if (e.type == std.c.DT.LNK or e.type == std.c.DT.UNKNOWN) {
            const full = try join(a, path, name);
            defer a.free(full);
            if (sys.stat_path(full, true)) |st| is_dir = st.is_dir();
        }
        try entries.append(a, .{ .name = try a.dupe(u8, name), .is_dir = is_dir });
    }
    return true;
}

fn is_dir_path(path: []const u8) bool {
    if (sys.stat_path(path, true)) |st| return st.is_dir();
    return false;
}

fn lstat_ok(path: []const u8) bool {
    return sys.stat_path(path, false) != null;
}

fn walk_all(sh: *Shell, a: Allocator, base: []const u8, depth: u32, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (depth > 64) return;
    var entries: std.ArrayList(Entry) = .empty;
    _ = try read_dir(a, base, &entries);
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        if (e.name[0] == '.' and !dotglob_eff(sh)) continue;
        const full = try join(a, base, e.name);
        if (e.is_dir) {
            const st = sys.stat_path(full, false);
            try out.append(a, full);
            if (st != null and !st.?.is_link()) try walk_all(sh, a, full, depth + 1, out);
        } else try out.append(a, full);
    }
}

fn walk_dirs(sh: *Shell, a: Allocator, base: []const u8, depth: u32, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (depth > 64) return;
    var entries: std.ArrayList(Entry) = .empty;
    _ = try read_dir(a, base, &entries);
    for (entries.items) |e| {
        if (!e.is_dir) continue;
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        if (e.name[0] == '.' and !dotglob_eff(sh)) continue;
        const full = try join(a, base, e.name);
        const st = sys.stat_path(full, false);
        try out.append(a, full);
        if (st != null and !st.?.is_link()) try walk_dirs(sh, a, full, depth + 1, out);
    }
}

fn globignore(sh: *Shell) ?[]const u8 {
    const v = sh.vars.get("GLOBIGNORE") orelse return null;
    const s = sh.scalar_of(v) orelse return null;
    if (s.len == 0) return null;
    return s;
}

fn dotglob_eff(sh: *Shell) bool {
    return sh.shopts[@intFromEnum(shell.Shopt.dotglob)] or globignore(sh) != null;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn expand(sh: *Shell, pat: []const u8, out: *std.ArrayList([]const u8)) Err!void {
    const a = sh.sa;
    var comps: std.ArrayList([]const u8) = .empty;
    try split_components(a, pat, &comps);
    var results: std.ArrayList([]const u8) = .empty;
    var first: usize = 0;
    if (pat.len > 0 and pat[0] == '/') {
        try results.append(a, "/");
        first = 1;
    } else try results.append(a, "");
    const trailing_slash = comps.items.len > 1 and comps.items[comps.items.len - 1].len == 0;
    var n_comps = comps.items.len;
    if (trailing_slash) n_comps -= 1;
    const o: pattern.Opts = .{ .extglob = sh.shopt(.extglob), .nocase = sh.shopt(.nocaseglob), .dot_literal = !dotglob_eff(sh), .utf8 = sh.utf8 };
    var ci: usize = first;
    while (ci < n_comps) : (ci += 1) {
        const comp = comps.items[ci];
        const is_last = ci + 1 == n_comps;
        if (comp.len == 0) continue;
        var next: std.ArrayList([]const u8) = .empty;
        for (results.items) |base| {
            if (sh.shopt(.globstar) and std.mem.eql(u8, comp, "**")) {
                if (is_last) {
                    if (base.len > 0) try next.append(a, try std.mem.concat(a, u8, &.{ base, "/" }));
                } else try next.append(a, base);
                if (is_last) {
                    var all: std.ArrayList([]const u8) = .empty;
                    try walk_all(sh, a, base, 0, &all);
                    try next.appendSlice(a, all.items);
                } else {
                    var ds: std.ArrayList([]const u8) = .empty;
                    try walk_dirs(sh, a, base, 0, &ds);
                    try next.appendSlice(a, ds.items);
                }
                continue;
            }
            if (!pattern.has_meta(comp, sh.shopt(.extglob))) {
                const lit = try pattern.unescape(a, comp);
                const cand = try join(a, base, lit);
                if (is_last) {
                    if (lstat_ok(cand)) {
                        if (trailing_slash and !is_dir_path(cand)) continue;
                        try next.append(a, cand);
                    }
                } else if (is_dir_path(cand)) try next.append(a, cand);
                continue;
            }
            var entries: std.ArrayList(Entry) = .empty;
            if (!(try read_dir(a, base, &entries))) continue;
            var matched: std.ArrayList([]const u8) = .empty;
            const explicit_dot = comp[0] == '.' or (comp.len > 1 and comp[0] == '\\' and comp[1] == '.');
            for (entries.items) |e| {
                if (e.name[0] == '.' and !explicit_dot and !dotglob_eff(sh)) continue;
                if (dotglob_eff(sh) and !explicit_dot and (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, ".."))) continue;
                if (!is_last and !e.is_dir) continue;
                if (trailing_slash and is_last and !e.is_dir) continue;
                var oo = o;
                oo.dot_literal = !dotglob_eff(sh) and e.name[0] == '.';
                if (e.name[0] == '.' and explicit_dot) oo.dot_literal = false;
                if (pattern.match(a, comp, e.name, oo)) try matched.append(a, try join(a, base, e.name));
            }
            std.mem.sort([]const u8, matched.items, {}, lessThan);
            try next.appendSlice(a, matched.items);
        }
        results = next;
        if (results.items.len == 0) return;
    }
    std.mem.sort([]const u8, results.items, {}, lessThan);
    const gi = globignore(sh);
    for (results.items) |r| {
        if (r.len == 0) continue;
        if (gi) |ign| {
            var skip = false;
            var it = std.mem.splitScalar(u8, ign, ':');
            while (it.next()) |p| {
                if (p.len > 0 and pattern.match(a, p, r, .{ .extglob = true })) {
                    skip = true;
                    break;
                }
            }
            const base_name = if (std.mem.findScalarLast(u8, r, '/')) |sl| r[sl + 1 ..] else r;
            if (std.mem.eql(u8, base_name, ".") or std.mem.eql(u8, base_name, "..")) skip = true;
            if (skip) continue;
        }
        if (trailing_slash and r[r.len - 1] != '/') {
            try out.append(a, try std.mem.concat(a, u8, &.{ r, "/" }));
        } else try out.append(a, r);
    }
}

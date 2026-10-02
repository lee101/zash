const std = @import("std");
const ast = @import("../ast.zig");
const sys = @import("sys.zig");
const shell = @import("shell.zig");
const vars_mod = @import("vars.zig");
const exec = @import("exec.zig");
const unparse = @import("unparse.zig");
const strutil = @import("strutil.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Var = vars_mod.Var;

pub const Kind = enum { declare, local, exp, readonly };

const Flags = struct {
    a: bool = false,
    A: bool = false,
    f: bool = false,
    F: bool = false,
    g: bool = false,
    p: bool = false,
    i: ?bool = null,
    l: ?bool = null,
    u: ?bool = null,
    c: ?bool = null,
    n: ?bool = null,
    r: ?bool = null,
    t: ?bool = null,
    x: ?bool = null,
    any_attr: bool = false,
};

pub fn escape_dq(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"', '\\', '$', '`' => try out.append(a, '\\'),
            else => {},
        }
        try out.append(a, c);
    }
}

fn attr_string(v: *const Var, buf: *[16]u8) []const u8 {
    var n: usize = 0;
    if (v.value == .indexed) {
        buf[n] = 'a';
        n += 1;
    }
    if (v.value == .assoc) {
        buf[n] = 'A';
        n += 1;
    }
    if (v.flags.integer) {
        buf[n] = 'i';
        n += 1;
    }
    if (v.flags.lower) {
        buf[n] = 'l';
        n += 1;
    }
    if (v.flags.nameref) {
        buf[n] = 'n';
        n += 1;
    }
    if (v.flags.readonly) {
        buf[n] = 'r';
        n += 1;
    }
    if (v.flags.trace) {
        buf[n] = 't';
        n += 1;
    }
    if (v.flags.upper) {
        buf[n] = 'u';
        n += 1;
    }
    if (v.flags.capital) {
        buf[n] = 'c';
        n += 1;
    }
    if (v.flags.exported) {
        buf[n] = 'x';
        n += 1;
    }
    return buf[0..n];
}

fn key_needs_quote(k: []const u8) bool {
    if (k.len == 0) return true;
    for (k) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return true;
    return false;
}

pub fn value_text(sh: *Shell, v: *Var, out: *std.ArrayList(u8)) Err!void {
    const a = sh.sa;
    switch (v.value) {
        .none => {},
        .str => |s| {
            try out.appendSlice(a, "=\"");
            try escape_dq(a, out, s);
            try out.append(a, '"');
        },
        .indexed => |*ix| {
            try out.appendSlice(a, "=(");
            for (ix.items.items, 0..) |e, i| {
                if (i > 0) try out.append(a, ' ');
                try out.print(a, "[{d}]=\"", .{e.idx});
                try escape_dq(a, out, e.val);
                try out.append(a, '"');
            }
            try out.append(a, ')');
        },
        .assoc => |*m| {
            try out.appendSlice(a, "=(");
            var it = m.map.iterator();
            while (it.next()) |e| {
                try out.append(a, '[');
                if (key_needs_quote(e.key_ptr.*)) {
                    try out.append(a, '"');
                    try escape_dq(a, out, e.key_ptr.*);
                    try out.append(a, '"');
                } else try out.appendSlice(a, e.key_ptr.*);
                try out.appendSlice(a, "]=\"");
                try escape_dq(a, out, e.value_ptr.*);
                try out.appendSlice(a, "\" ");
            }
            try out.append(a, ')');
        },
    }
}

pub fn print_declare(sh: *Shell, v: *Var, out: *std.ArrayList(u8)) Err!void {
    const a = sh.sa;
    var buf: [16]u8 = undefined;
    const attrs = attr_string(v, &buf);
    try out.appendSlice(a, "declare -");
    if (attrs.len == 0) try out.append(a, '-') else try out.appendSlice(a, attrs);
    try out.append(a, ' ');
    try out.appendSlice(a, v.name);
    if (v.special != .none and v.value == .none) {
        if (sh.scalar_of(v)) |s| {
            try out.appendSlice(a, "=\"");
            try escape_dq(a, out, s);
            try out.append(a, '"');
        }
    } else try value_text(sh, v, out);
    try out.append(a, '\n');
}

fn sorted_names(sh: *Shell) Err![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = sh.vars.map.iterator();
    while (it.next()) |e| try names.append(sh.sa, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, less);
    return names.items;
}

fn less(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn function_text(sh: *Shell, f: *const shell.Func, out: *std.ArrayList(u8)) Err!void {
    try unparse.function_text(sh, f.name, f.body, out);
}

pub fn list_functions(sh: *Shell, names_only: bool, only_exported: bool) Err!void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = sh.funcs.iterator();
    while (it.next()) |e| try names.append(sh.sa, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, less);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |n| {
        const f = sh.funcs.get(n).?;
        if (only_exported and !f.exported) continue;
        if (names_only) {
            try out.print(sh.sa, "declare -f{s} {s}\n", .{ if (f.exported) "x" else "", n });
        } else try function_text(sh, f, &out);
    }
    _ = sh.out(out.items);
}

pub fn run(sh: *Shell, kind: Kind, items: []const exec.DeclItem) Err!u8 {
    const name = switch (items[0]) {
        .arg => |s| s,
        else => "declare",
    };
    var fl: Flags = .{};
    var i: usize = 1;
    var status: u8 = 0;
    while (i < items.len) : (i += 1) {
        const s = switch (items[i]) {
            .arg => |x| x,
            .assign => break,
        };
        if (s.len < 2 or (s[0] != '-' and s[0] != '+')) break;
        if (std.mem.eql(u8, s, "--")) {
            i += 1;
            break;
        }
        const on = s[0] == '-';
        for (s[1..]) |c| {
            switch (c) {
                'a' => fl.a = true,
                'A' => fl.A = true,
                'f' => fl.f = true,
                'F' => fl.F = true,
                'g' => fl.g = true,
                'p' => fl.p = true,
                'i' => fl.i = on,
                'l' => fl.l = on,
                'u' => fl.u = on,
                'c' => fl.c = on,
                'n' => fl.n = on,
                'r' => fl.r = on,
                't' => fl.t = on,
                'x' => fl.x = on,
                else => {
                    sh.bmsg(name, "{c}{c}: invalid option", .{ s[0], c });
                    const usage: []const u8 = switch (kind) {
                        .declare => "declare [-aAfFgiIlnrtux] [name[=value] ...] or declare -p [-aAfFilnrtux] [name ...]",
                        .local => "local [option] name[=value] ...",
                        .exp => "export [-fn] [name[=value] ...] or export -p",
                        .readonly => "readonly [-aAf] [name[=value] ...] or readonly -p",
                    };
                    sh.usage_msg(name, usage);
                    return 2;
                },
            }
        }
    }
    const rest = items[i..];
    if (kind == .local and !sh.has_func_frame()) {
        sh.bmsg(name, "can only be used in a function", .{});
        return 1;
    }
    if (kind == .exp) {
        if (fl.x == null) fl.x = true;
        if (fl.n == true) {
            fl.x = false;
            fl.n = null;
        }
    }
    if (kind == .readonly) fl.r = true;
    if (fl.f or fl.F) {
        return run_funcs(sh, kind, fl, rest);
    }
    const listing = rest.len == 0;
    if (listing and kind != .local) {
        var out: std.ArrayList(u8) = .empty;
        const names = try sorted_names(sh);
        const show_plain = kind == .declare and !fl.p and fl.i == null and fl.r == null and fl.x == null and !fl.a and !fl.A and fl.n == null and fl.l == null and fl.u == null;
        for (names) |n| {
            const v = sh.vars.get(n).?;
            if (v.special != .none and v.value == .none and v.special != .random and v.special != .seconds and v.special != .lineno) continue;
            if (v.value == .none and v.special == .none and !v.flags.exported and !v.flags.readonly and !v.flags.integer and !v.flags.nameref and !v.flags.upper and !v.flags.lower and !v.flags.trace) {
                if (!show_plain) continue;
            }
            if (kind == .exp and !v.flags.exported) continue;
            if (kind == .readonly and !v.flags.readonly) continue;
            if (fl.a and v.value != .indexed) continue;
            if (fl.A and v.value != .assoc) continue;
            if (fl.i == true and !v.flags.integer) continue;
            if (fl.r == true and kind == .declare and !v.flags.readonly) continue;
            if (fl.x == true and kind == .declare and !v.flags.exported) continue;
            if (fl.n == true and !v.flags.nameref) continue;
            if (fl.l == true and !v.flags.lower) continue;
            if (fl.u == true and !v.flags.upper) continue;
            if (show_plain) {
                try print_set_style(sh, v, &out);
            } else try print_declare(sh, v, &out);
        }
        if (show_plain) {
            _ = sh.out(out.items);
            try list_functions(sh, false, false);
            return 0;
        }
        _ = sh.out(out.items);
        return 0;
    }
    if (fl.p and kind != .local) {
        var out: std.ArrayList(u8) = .empty;
        for (rest) |it| {
            const nm = switch (it) {
                .arg => |s| s,
                .assign => |as| as.name,
            };
            const v = sh.find(nm) orelse {
                sh.bmsg(name, "{s}: not found", .{nm});
                status = 1;
                continue;
            };
            try print_declare(sh, v, &out);
        }
        _ = sh.out(out.items);
        return status;
    }
    const local_scope = kind == .local or (kind == .declare and sh.frames.items.len > 0 and !fl.g);
    for (rest) |it| {
        const st = try apply_one(sh, name, kind, fl, it, local_scope);
        if (st != 0) status = st;
    }
    return status;
}

pub fn print_set_style(sh: *Shell, v: *Var, out: *std.ArrayList(u8)) Err!void {
    const a = sh.sa;
    switch (v.value) {
        .none => {
            if (v.special != .none) {
                if (sh.scalar_of(v)) |s| {
                    try out.appendSlice(a, v.name);
                    try out.append(a, '=');
                    try set_quote(a, out, s);
                    try out.append(a, '\n');
                }
            }
        },
        .str => |s| {
            try out.appendSlice(a, v.name);
            try out.append(a, '=');
            try set_quote(a, out, s);
            try out.append(a, '\n');
        },
        else => {
            try out.appendSlice(a, v.name);
            var tmp: std.ArrayList(u8) = .empty;
            try value_text(sh, v, &tmp);
            try out.appendSlice(a, tmp.items);
            try out.append(a, '\n');
        },
    }
}

pub fn set_quote(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len == 0) return;
    if (strutil.has_ctl(s)) return strutil.ansi_quote(a, out, s);
    var plain = true;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', ',', '@', '%', '+', '=', '~', '^' => {},
            '#' => {
                if (s[0] == '#') plain = false;
            },
            else => plain = false,
        }
    }
    if (plain) return out.appendSlice(a, s);
    return strutil.single_quote(a, out, s);
}

fn run_funcs(sh: *Shell, kind: Kind, fl: Flags, rest: []const exec.DeclItem) Err!u8 {
    var status: u8 = 0;
    if (rest.len == 0) {
        if (kind == .exp or kind == .declare or kind == .readonly) {
            try list_functions(sh, fl.F, kind == .exp and fl.x == true);
        }
        return 0;
    }
    var out: std.ArrayList(u8) = .empty;
    for (rest) |it| {
        const nm = switch (it) {
            .arg => |s| s,
            .assign => |as| as.name,
        };
        if (kind == .exp and fl.x != null) {
            const f = sh.funcs.get(nm) orelse {
                sh.bmsg("export", "{s}: not a function", .{nm});
                status = 1;
                continue;
            };
            f.exported = fl.x.?;
            continue;
        }
        if (kind == .readonly) {
            if (sh.funcs.get(nm)) |f| f.readonly = true else status = 1;
            continue;
        }
        const f = sh.funcs.get(nm) orelse {
            status = 1;
            continue;
        };
        if (fl.F) {
            if (fl.p or true) {
                try out.print(sh.sa, "{s}\n", .{nm});
            }
        } else try function_text(sh, f, &out);
        if (fl.x == true and !fl.F) f.exported = true;
    }
    _ = sh.out(out.items);
    return status;
}

fn apply_attrs(sh: *Shell, v: *Var, fl: Flags) Err!void {
    if (fl.x) |x| {
        v.flags.exported = x;
        sh.mark_env();
    }
    if (fl.i) |x| v.flags.integer = x;
    if (fl.l) |x| {
        v.flags.lower = x;
        if (x) v.flags.upper = false;
    }
    if (fl.u) |x| {
        v.flags.upper = x;
        if (x) v.flags.lower = false;
    }
    if (fl.c) |x| v.flags.capital = x;
    if (fl.t) |x| v.flags.trace = x;
}

fn convert_existing_case(sh: *Shell, v: *Var) Err!void {
    if (!(v.flags.lower or v.flags.upper or v.flags.capital)) return;
    if (v.value == .str) {
        const s = v.value.str;
        for (s) |*c| {
            if (v.flags.lower) c.* = std.ascii.toLower(c.*) else if (v.flags.upper) c.* = std.ascii.toUpper(c.*);
        }
    }
    _ = sh;
}

fn apply_one(sh: *Shell, name: []const u8, kind: Kind, fl: Flags, it: exec.DeclItem, local_scope: bool) Err!u8 {
    const vname = switch (it) {
        .arg => |s| s,
        .assign => |as| as.name,
    };
    if (!Shell.is_valid_name(vname)) {
        const full: []const u8 = switch (it) {
            .arg => |s| s,
            .assign => |as| blk: {
                var w: unparse.W = .{ .sh = sh, .a = sh.sa };
                try w.put_assign(as);
                break :blk w.out.items;
            },
        };
        sh.bmsg(name, "`{s}': not a valid identifier", .{full});
        return 1;
    }
    var v: *Var = undefined;
    if (local_scope) {
        v = try sh.push_local(vname);
    } else {
        v = sh.find(vname) orelse try sh.new_var(vname);
        if (fl.n == null or fl.n == false) {} else if (v.flags.nameref) {}
        if (v.flags.nameref and fl.n != true and it == .assign) {
            if (sh.vars.get(vname)) |direct| v = direct;
        }
    }
    const attr_change = fl.i != null or fl.l != null or fl.u != null or fl.c != null or fl.n != null or fl.a or fl.A or fl.t != null or (fl.r != null and !fl.r.?);
    if (v.flags.readonly and (it == .assign or attr_change)) {
        sh.bmsg(name, "{s}: readonly variable", .{vname});
        return 1;
    }
    if (fl.a and v.value == .assoc) {
        sh.bmsg(name, "{s}: cannot convert associative to indexed array", .{vname});
        return 1;
    }
    if (fl.A and v.value == .indexed) {
        sh.bmsg(name, "{s}: cannot convert indexed to associative array", .{vname});
        return 1;
    }
    if (fl.a) try sh.declare_indexed(v);
    if (fl.A) try sh.declare_assoc(v);
    if (fl.n) |n| {
        if (n) {
            if (it == .assign and it.assign.value == .scalar) {
                const target = try exec_word(sh, it.assign.value.scalar);
                if (target.len > 0 and !Shell.is_valid_name(strip_sub(target))) {
                    sh.bmsg(name, "`{s}': invalid variable name for name reference", .{target});
                    return 1;
                }
                if (std.mem.eql(u8, target, vname)) {
                    sh.bmsg(name, "{s}: nameref variable self references not allowed", .{vname});
                    return 1;
                }
                v.flags.nameref = true;
                try sh.set_str_raw(v, target);
                try apply_attrs(sh, v, fl);
                return 0;
            }
            v.flags.nameref = true;
        } else v.flags.nameref = false;
    }
    try apply_attrs(sh, v, fl);
    switch (it) {
        .arg => {},
        .assign => |as| {
            exec.do_assign(sh, as) catch |e| switch (e) {
                error.Abort => return 1,
                else => return e,
            };
            if (sh.find(vname)) |nv| v = nv;
        },
    }
    try convert_existing_case(sh, v);
    if (fl.r) |r| {
        if (r) v.flags.readonly = true;
    }
    if (kind == .exp and it == .arg) sh.mark_env();
    return 0;
}

fn strip_sub(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '[')) |lb| return s[0..lb];
    return s;
}

fn exec_word(sh: *Shell, w: ast.Word) Err![]const u8 {
    return @import("expand.zig").word_string(sh, w);
}

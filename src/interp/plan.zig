const std = @import("std");
const ast = @import("../ast.zig");
const shell = @import("shell.zig");
const fuse = @import("fuse.zig");
const builtins = @import("builtins.zig");
const registry = @import("../utils/registry.zig");
const Shell = shell.Shell;

pub const Strategy = enum { general, fused };

fn plain_lit(w: ast.Word) ?[]const u8 {
    if (w.parts.len == 1) switch (w.parts[0]) {
        .lit => |t| return t,
        else => {},
    };
    return null;
}

fn part_pure(p: ast.Part) bool {
    switch (p) {
        .lit, .quoted, .ansi_c, .variable, .tilde => return true,
        .dquote => |inner| {
            for (inner) |ip| if (!part_pure(ip)) return false;
            return true;
        },
        .param => |pe| {
            switch (pe.op) {
                .none, .prefix_names, .transform => return true,
                .trim => |t| return word_pure(t.pattern),
                .replace => |r| return word_pure(r.pattern) and (r.replacement == null or word_pure(r.replacement.?)),
                .case_mod => return true,
                .use_default => |c| return word_pure(c.word),
                .use_alt => |c| return word_pure(c.word),
                else => return false,
            }
        },
        .brace_list, .brace_seq => return true,
        else => return false,
    }
}

fn word_pure(w: ast.Word) bool {
    for (w.parts) |p| if (!part_pure(p)) return false;
    return true;
}

fn redir_ok(r: ast.Redirect) bool {
    switch (r.fd) {
        .named => return false,
        .num => |n| if (n > 2) return false,
        .none => {},
    }
    switch (r.op) {
        .in, .out, .append, .clobber, .out_err, .append_err, .dup_out => {},
        else => return false,
    }
    return word_pure(r.target);
}

pub fn classify(sh: *Shell, p: ast.Pipeline) Strategy {
    if (!fuse.supported) return .general;
    if (p.commands.len < 2 or p.commands.len > 16) return .general;
    if (sh.trap_debug.kind == .cmd or sh.opt(.verbose)) return .general;
    for (p.commands) |c| {
        if (c.body != .simple) return .general;
        const s = c.body.simple;
        if (s.assigns.len != 0 or s.words.len == 0) return .general;
        const name = plain_lit(s.words[0]) orelse return .general;
        if (registry.lookup(name) == null) return .general;
        if (builtins.is_builtin(name)) return .general;
        for (s.words) |w| if (!word_pure(w)) return .general;
        for (c.redirs) |r| if (!redir_ok(r)) return .general;
    }
    return .fused;
}

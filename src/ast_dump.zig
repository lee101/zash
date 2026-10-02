const std = @import("std");
const ast = @import("ast.zig");

const W = std.Io.Writer;
pub const Error = W.Error;

pub fn dump_alloc(alloc: std.mem.Allocator, list: ast.List) std.mem.Allocator.Error![]u8 {
    var aw: W.Allocating = .init(alloc);
    errdefer aw.deinit();
    dump_list(&aw.writer, list) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn dump_list(w: *W, list: ast.List) Error!void {
    try w.writeAll("(list");
    for (list.items) |it| {
        try w.writeByte(' ');
        try dump_item(w, it);
    }
    try w.writeByte(')');
}

fn dump_item(w: *W, it: ast.Item) Error!void {
    if (it.background) try w.writeAll("(& ");
    try dump_and_or(w, it.and_or);
    if (it.background) try w.writeByte(')');
}

fn dump_and_or(w: *W, ao: ast.AndOr) Error!void {
    for (ao.rest) |l| try w.writeAll(if (l.op == .and_if) "(&& " else "(|| ");
    try dump_pipeline(w, ao.first);
    for (ao.rest) |l| {
        try w.writeByte(' ');
        try dump_pipeline(w, l.pipeline);
        try w.writeByte(')');
    }
}

fn dump_pipeline(w: *W, p: ast.Pipeline) Error!void {
    if (p.negate) try w.writeAll("(! ");
    switch (p.time) {
        .none => {},
        .time => try w.writeAll("(time "),
        .time_posix => try w.writeAll("(time-p "),
    }
    if (p.commands.len == 0) {
        try w.writeAll("(empty)");
    } else if (p.commands.len == 1) {
        try dump_command(w, p.commands[0]);
    } else {
        try w.writeAll("(pipe");
        for (p.commands, 0..) |c, i| {
            if (i > 0) try w.writeAll(if (p.pipe_stderr.len > 0 and p.pipe_stderr[i - 1]) " |&" else " |");
            try w.writeByte(' ');
            try dump_command(w, c);
        }
        try w.writeByte(')');
    }
    if (p.time != .none) try w.writeByte(')');
    if (p.negate) try w.writeByte(')');
}

fn dump_command(w: *W, c: ast.Command) Error!void {
    const compound_redirs = c.redirs.len > 0 and c.body != .simple;
    if (compound_redirs) try w.writeAll("(R ");
    switch (c.body) {
        .simple => |s| {
            try w.writeAll("(cmd");
            for (s.assigns) |a| {
                try w.writeByte(' ');
                try dump_assign(w, a);
            }
            for (s.words) |wd| {
                try w.writeByte(' ');
                try dump_word(w, wd);
            }
            for (c.redirs) |r| {
                try w.writeByte(' ');
                try dump_redirect(w, r);
            }
            try w.writeByte(')');
        },
        .subshell => |l| {
            try w.writeAll("(sub ");
            try dump_list(w, l);
            try w.writeByte(')');
        },
        .group => |l| {
            try w.writeAll("(grp ");
            try dump_list(w, l);
            try w.writeByte(')');
        },
        .if_cmd => |i| {
            try w.writeAll("(if");
            for (i.clauses, 0..) |cl, n| {
                if (n > 0) try w.writeAll(" (elif");
                try w.writeByte(' ');
                try dump_list(w, cl.cond);
                try w.writeByte(' ');
                try dump_list(w, cl.body);
                if (n > 0) try w.writeByte(')');
            }
            if (i.else_body) |e| {
                try w.writeAll(" (else ");
                try dump_list(w, e);
                try w.writeByte(')');
            }
            try w.writeByte(')');
        },
        .loop => |l| {
            try w.writeAll(if (l.until) "(until " else "(while ");
            try dump_list(w, l.cond);
            try w.writeByte(' ');
            try dump_list(w, l.body);
            try w.writeByte(')');
        },
        .for_in => |f| try dump_for(w, "for", f),
        .select => |f| try dump_for(w, "select", f),
        .arith_for => |f| {
            try w.writeAll("(for-arith ");
            try dump_opt_arith(w, f.init);
            try w.writeByte(' ');
            try dump_opt_arith(w, f.cond);
            try w.writeByte(' ');
            try dump_opt_arith(w, f.step);
            try w.writeByte(' ');
            try dump_list(w, f.body);
            try w.writeByte(')');
        },
        .case => |cs| {
            try w.writeAll("(case ");
            try dump_word(w, cs.word);
            for (cs.clauses) |cl| {
                try w.writeAll(" ((");
                for (cl.patterns, 0..) |p, i| {
                    if (i > 0) try w.writeByte(' ');
                    try dump_word(w, p);
                }
                try w.writeAll(") ");
                try dump_list(w, cl.body);
                switch (cl.term) {
                    .break_ => {},
                    .fallthrough => try w.writeAll(" ;&"),
                    .test_next => try w.writeAll(" ;;&"),
                }
                try w.writeByte(')');
            }
            try w.writeByte(')');
        },
        .function => |f| {
            try w.print("({s} ", .{if (f.keyword) "fn-kw" else "fn"});
            try dump_str(w, f.name);
            try w.writeByte(' ');
            try dump_command(w, f.body.*);
            try w.writeByte(')');
        },
        .cond => |cn| {
            try w.writeAll("(cond ");
            try dump_cond(w, cn.*);
            try w.writeByte(')');
        },
        .arith_cmd => |e| {
            try w.writeAll("(arith-cmd ");
            try dump_arith(w, e);
            try w.writeByte(')');
        },
        .coproc => |cp| {
            try w.writeAll("(coproc ");
            if (cp.name) |n| {
                try dump_str(w, n);
                try w.writeByte(' ');
            }
            try dump_command(w, cp.body.*);
            try w.writeByte(')');
        },
    }
    if (compound_redirs) {
        for (c.redirs) |r| {
            try w.writeByte(' ');
            try dump_redirect(w, r);
        }
        try w.writeByte(')');
    }
}

fn dump_for(w: *W, name: []const u8, f: ast.ForIn) Error!void {
    try w.print("({s} ", .{name});
    try dump_str(w, f.name);
    if (f.words) |ws| {
        try w.writeAll(" (in");
        for (ws) |wd| {
            try w.writeByte(' ');
            try dump_word(w, wd);
        }
        try w.writeByte(')');
    }
    try w.writeByte(' ');
    try dump_list(w, f.body);
    try w.writeByte(')');
}

fn dump_opt_arith(w: *W, e: ?*const ast.Arith) Error!void {
    if (e) |x| try dump_arith(w, x) else try w.writeByte('_');
}

fn dump_assign(w: *W, a: ast.Assign) Error!void {
    try w.writeAll(if (a.append) "(+= " else "(= ");
    try w.writeAll(a.name);
    if (a.index) |ix| {
        try w.writeByte('[');
        try dump_word(w, ix);
        try w.writeByte(']');
    }
    try w.writeByte(' ');
    switch (a.value) {
        .scalar => |v| try dump_word(w, v),
        .array => |elems| try dump_array(w, elems),
    }
    try w.writeByte(')');
}

fn dump_array(w: *W, elems: []const ast.ArrayElem) Error!void {
    try w.writeAll("(arr");
    for (elems) |e| {
        try w.writeByte(' ');
        if (e.key) |k| {
            try w.writeAll("(kv ");
            try dump_word(w, k);
            try w.writeByte(' ');
            try dump_word(w, e.value);
            try w.writeByte(')');
        } else try dump_word(w, e.value);
    }
    try w.writeByte(')');
}

fn redir_op_str(op: ast.RedirOp) []const u8 {
    return switch (op) {
        .in => "<",
        .out => ">",
        .append => ">>",
        .clobber => ">|",
        .read_write => "<>",
        .dup_in => "<&",
        .dup_out => ">&",
        .here_str => "<<<",
        .heredoc => "<<",
        .heredoc_strip => "<<-",
        .out_err => "&>",
        .append_err => "&>>",
    };
}

fn dump_redirect(w: *W, r: ast.Redirect) Error!void {
    try w.writeAll("(r ");
    switch (r.fd) {
        .none => {},
        .num => |n| try w.print("{d} ", .{n}),
        .named => |n| try w.print("{{{s}}} ", .{n}),
    }
    try w.writeAll(redir_op_str(r.op));
    try w.writeByte(' ');
    if (r.heredoc) |h| {
        try dump_str(w, h.delimiter);
        try w.writeAll(if (h.quoted) " q " else " u ");
        try dump_word_full(w, h.body);
    } else try dump_word(w, r.target);
    try w.writeByte(')');
}

pub fn dump_str(w: *W, s: []const u8) Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11...31, 127 => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn dump_word(w: *W, wd: ast.Word) Error!void {
    if (ast.word_is_plain_lit(wd)) |t| return dump_str(w, t);
    try dump_word_full(w, wd);
}

fn dump_word_full(w: *W, wd: ast.Word) Error!void {
    try w.writeAll("(w");
    for (wd.parts) |p| {
        try w.writeByte(' ');
        try dump_part(w, p);
    }
    try w.writeByte(')');
}

fn dump_part(w: *W, p: ast.Part) Error!void {
    switch (p) {
        .lit => |t| try dump_str(w, t),
        .quoted => |t| {
            try w.writeAll("(q ");
            try dump_str(w, t);
            try w.writeByte(')');
        },
        .ansi_c => |t| {
            try w.writeAll("(ansi ");
            try dump_str(w, t);
            try w.writeByte(')');
        },
        .dquote => |ps| {
            try w.writeAll("(dq");
            for (ps) |x| {
                try w.writeByte(' ');
                try dump_part(w, x);
            }
            try w.writeByte(')');
        },
        .variable => |n| try w.print("(v {s})", .{n}),
        .param => |pe| try dump_param(w, pe.*),
        .cmd_subst => |cs| {
            try w.writeAll(if (cs.backtick) "(bt " else "(cs ");
            try dump_list(w, cs.body);
            try w.writeByte(')');
        },
        .arith => |e| {
            try w.writeAll("(arith ");
            try dump_arith(w, e);
            try w.writeByte(')');
        },
        .proc_subst => |ps| {
            try w.writeAll(if (ps.input) "(psi " else "(pso ");
            try dump_list(w, ps.body);
            try w.writeByte(')');
        },
        .tilde => |t| {
            try w.writeAll("(tilde ");
            try dump_str(w, t);
            try w.writeByte(')');
        },
        .brace_list => |alts| {
            try w.writeAll("(brace");
            for (alts) |a| {
                try w.writeByte(' ');
                try dump_word(w, a);
            }
            try w.writeByte(')');
        },
        .brace_seq => |s| {
            try w.writeAll(if (s.chars) "(seqc " else "(seq ");
            try dump_str(w, s.from);
            try w.writeByte(' ');
            try dump_str(w, s.to);
            if (s.step) |st| {
                try w.writeByte(' ');
                try dump_str(w, st);
            }
            try w.writeByte(')');
        },
        .array_init => |elems| try dump_array(w, elems),
        .bad_subst => |t| {
            try w.writeAll("(bad ");
            try dump_str(w, t);
            try w.writeByte(')');
        },
    }
}

fn dump_param(w: *W, pe: ast.ParamExp) Error!void {
    try w.writeAll("(p ");
    if (pe.indirect) try w.writeAll("ind ");
    if (pe.length) try w.writeAll("len ");
    try w.writeAll(pe.name);
    if (pe.subscript) |s| switch (s) {
        .at => try w.writeAll("[@]"),
        .star => try w.writeAll("[*]"),
        .index => |ix| {
            try w.writeByte('[');
            try dump_word(w, ix);
            try w.writeByte(']');
        },
    };
    switch (pe.op) {
        .none => {},
        .use_default => |c| try dump_cw(w, if (c.colon) ":-" else "-", c.word),
        .assign_default => |c| try dump_cw(w, if (c.colon) ":=" else "=", c.word),
        .error_unset => |c| try dump_cw(w, if (c.colon) ":?" else "?", c.word),
        .use_alt => |c| try dump_cw(w, if (c.colon) ":+" else "+", c.word),
        .trim => |t| try dump_cw(w, switch (t.kind) {
            .prefix => "#",
            .prefix_longest => "##",
            .suffix => "%",
            .suffix_longest => "%%",
        }, t.pattern),
        .replace => |r| {
            try w.print(" ({s} ", .{switch (r.kind) {
                .first => "/",
                .all => "//",
                .prefix => "/#",
                .suffix => "/%",
            }});
            try dump_word(w, r.pattern);
            if (r.replacement) |rep| {
                try w.writeByte(' ');
                try dump_word(w, rep);
            }
            try w.writeByte(')');
        },
        .case_mod => |c| {
            try w.print(" ({s}", .{if (c.upper) (if (c.all) "^^" else "^") else (if (c.all) ",," else ",")});
            if (c.pattern) |pt| {
                try w.writeByte(' ');
                try dump_word(w, pt);
            }
            try w.writeByte(')');
        },
        .substring => |s| {
            try w.writeAll(" (sub ");
            try dump_arith(w, s.offset);
            if (s.length) |l| {
                try w.writeByte(' ');
                try dump_arith(w, l);
            }
            try w.writeByte(')');
        },
        .transform => |c| try w.print(" (@ {c})", .{c}),
        .prefix_names => |k| try w.print(" (names {s})", .{if (k == .at) "@" else "*"}),
    }
    try w.writeByte(')');
}

fn dump_cw(w: *W, op: []const u8, word: ast.Word) Error!void {
    try w.print(" ({s} ", .{op});
    try dump_word(w, word);
    try w.writeByte(')');
}

fn binop_str(op: ast.BinOp) []const u8 {
    return switch (op) {
        .mul => "*",
        .div => "/",
        .mod => "%",
        .add => "+",
        .sub => "-",
        .shl => "<<",
        .shr => ">>",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .eq => "==",
        .ne => "!=",
        .bit_and => "&",
        .bit_xor => "^",
        .bit_or => "|",
        .log_and => "&&",
        .log_or => "||",
        .pow => "**",
    };
}

pub fn dump_arith(w: *W, e: *const ast.Arith) Error!void {
    switch (e.*) {
        .num => |n| try w.print("{d}", .{n}),
        .bad_num => |t| {
            try w.writeAll("(badnum ");
            try dump_str(w, t);
            try w.writeByte(')');
        },
        .variable => |v| {
            if (v.index) |ix| {
                try w.print("(idx {s} ", .{v.name});
                try dump_arith(w, ix);
                try w.writeByte(')');
            } else try w.writeAll(v.name);
        },
        .expansion => |wd| {
            try w.writeAll("(exp ");
            try dump_word(w, wd);
            try w.writeByte(')');
        },
        .unary => |u| {
            try w.print("({s} ", .{switch (u.op) {
                .neg => "neg",
                .plus => "pos",
                .log_not => "!",
                .bit_not => "~",
            }});
            try dump_arith(w, u.operand);
            try w.writeByte(')');
        },
        .incdec => |i| {
            try w.print("({s} ", .{switch (i.kind) {
                .pre_inc => "pre++",
                .pre_dec => "pre--",
                .post_inc => "post++",
                .post_dec => "post--",
            }});
            try dump_arith(w, i.target);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{binop_str(b.op)});
            try dump_arith(w, b.lhs);
            try w.writeByte(' ');
            try dump_arith(w, b.rhs);
            try w.writeByte(')');
        },
        .assign => |a| {
            if (a.op) |op| try w.print("({s}= ", .{binop_str(op)}) else try w.writeAll("(= ");
            try dump_arith(w, a.target);
            try w.writeByte(' ');
            try dump_arith(w, a.value);
            try w.writeByte(')');
        },
        .ternary => |t| {
            try w.writeAll("(? ");
            try dump_arith(w, t.cond);
            try w.writeByte(' ');
            try dump_arith(w, t.then);
            try w.writeByte(' ');
            try dump_arith(w, t.otherwise);
            try w.writeByte(')');
        },
        .comma => |c| {
            try w.writeAll("(, ");
            try dump_arith(w, c.lhs);
            try w.writeByte(' ');
            try dump_arith(w, c.rhs);
            try w.writeByte(')');
        },
        .invalid => |i| {
            try w.writeAll("(invalid ");
            try dump_str(w, i.msg);
            try w.writeByte(')');
        },
    }
}

fn dump_cond(w: *W, c: ast.Cond) Error!void {
    switch (c) {
        .word => |wd| try dump_word(w, wd),
        .unary => |u| {
            try w.print("(-{s} ", .{@tagName(u.op)});
            try dump_word(w, u.arg);
            try w.writeByte(')');
        },
        .binary => |b| {
            try w.print("({s} ", .{switch (b.op) {
                .eq => "=",
                .eq2 => "==",
                .ne => "!=",
                .match => "=~",
                .lt => "<",
                .gt => ">",
                .int_eq => "-eq",
                .int_ne => "-ne",
                .int_lt => "-lt",
                .int_le => "-le",
                .int_gt => "-gt",
                .int_ge => "-ge",
                .nt => "-nt",
                .ot => "-ot",
                .ef => "-ef",
            }});
            try dump_word(w, b.lhs);
            try w.writeByte(' ');
            try dump_word(w, b.rhs);
            try w.writeByte(')');
        },
        .not => |x| {
            try w.writeAll("(! ");
            try dump_cond(w, x.*);
            try w.writeByte(')');
        },
        .and_ => |x| {
            try w.writeAll("(&& ");
            try dump_cond(w, x.lhs.*);
            try w.writeByte(' ');
            try dump_cond(w, x.rhs.*);
            try w.writeByte(')');
        },
        .or_ => |x| {
            try w.writeAll("(|| ");
            try dump_cond(w, x.lhs.*);
            try w.writeByte(' ');
            try dump_cond(w, x.rhs.*);
            try w.writeByte(')');
        },
        .group => |x| {
            try w.writeAll("(grp ");
            try dump_cond(w, x.*);
            try w.writeByte(')');
        },
    }
}

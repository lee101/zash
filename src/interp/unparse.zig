const std = @import("std");
const ast = @import("../ast.zig");
const shell = @import("shell.zig");
const arith = @import("arith.zig");
const strutil = @import("strutil.zig");
const Shell = shell.Shell;
const Err = shell.Err;
const Allocator = std.mem.Allocator;

pub const W = struct {
    sh: *Shell,
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    indent: u32 = 0,

    pub fn put(self: *W, s: []const u8) Err!void {
        try self.out.appendSlice(self.a, s);
    }

    fn ch(self: *W, c: u8) Err!void {
        try self.out.append(self.a, c);
    }

    fn pad(self: *W) Err!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) try self.put("    ");
    }

    pub fn word(self: *W, w: ast.Word) Err!void {
        for (w.parts) |p| try self.part(p);
    }

    pub fn part(self: *W, p: ast.Part) Err!void {
        switch (p) {
            .lit => |t| try self.put(t),
            .quoted => |t| {
                if (t.len == 1 and (t[0] == '\\' or !std.ascii.isAlphanumeric(t[0])) and t[0] != '\'') {
                    try self.ch('\\');
                    try self.put(t);
                } else try strutil.single_quote(self.a, &self.out, t);
            },
            .ansi_c => |t| try strutil.single_quote(self.a, &self.out, t),
            .dquote => |inner| {
                try self.ch('"');
                for (inner) |ip| try self.part(ip);
                try self.ch('"');
            },
            .variable => |n| {
                try self.ch('$');
                try self.put(n);
            },
            .param => |pe| try self.param(pe),
            .cmd_subst => |cs| {
                try self.put(if (cs.backtick) "`" else "$(");
                try self.list_inline(cs.body);
                try self.put(if (cs.backtick) "`" else ")");
            },
            .arith => |n| {
                try self.put("$((");
                try arith.render(self.sh, n, &self.out);
                try self.put("))");
            },
            .proc_subst => |ps| {
                try self.put(if (ps.input) "<(" else ">(");
                try self.list_inline(ps.body);
                try self.ch(')');
            },
            .tilde => |t| {
                try self.ch('~');
                try self.put(t);
            },
            .brace_list => |alts| {
                try self.ch('{');
                for (alts, 0..) |alt, i| {
                    if (i > 0) try self.ch(',');
                    try self.word(alt);
                }
                try self.ch('}');
            },
            .brace_seq => |s| {
                try self.ch('{');
                try self.put(s.from);
                try self.put("..");
                try self.put(s.to);
                if (s.step) |st| {
                    try self.put("..");
                    try self.put(st);
                }
                try self.ch('}');
            },
            .array_init => |elems| {
                try self.ch('(');
                for (elems, 0..) |e, i| {
                    if (i > 0) try self.ch(' ');
                    if (e.key) |k| {
                        try self.ch('[');
                        try self.word(k);
                        try self.put("]=");
                    }
                    try self.word(e.value);
                }
                try self.ch(')');
            },
            .bad_subst => |t| try self.put(t),
        }
    }

    fn subscript(self: *W, s: ast.Subscript) Err!void {
        switch (s) {
            .at => try self.put("[@]"),
            .star => try self.put("[*]"),
            .index => |w| {
                try self.ch('[');
                try self.word(w);
                try self.ch(']');
            },
        }
    }

    fn param(self: *W, pe: *const ast.ParamExp) Err!void {
        try self.put("${");
        if (pe.length) try self.ch('#');
        if (pe.indirect) try self.ch('!');
        try self.put(pe.name);
        if (pe.subscript) |s| try self.subscript(s);
        switch (pe.op) {
            .none => {},
            .use_default => |c| try self.cond_op("-", c),
            .assign_default => |c| try self.cond_op("=", c),
            .error_unset => |c| try self.cond_op("?", c),
            .use_alt => |c| try self.cond_op("+", c),
            .trim => |t| {
                try self.put(switch (t.kind) {
                    .prefix => "#",
                    .prefix_longest => "##",
                    .suffix => "%",
                    .suffix_longest => "%%",
                });
                try self.word(t.pattern);
            },
            .replace => |r| {
                try self.put(switch (r.kind) {
                    .first => "/",
                    .all => "//",
                    .prefix => "/#",
                    .suffix => "/%",
                });
                try self.word(r.pattern);
                if (r.replacement) |rw| {
                    try self.ch('/');
                    try self.word(rw);
                }
            },
            .case_mod => |c| {
                const ch_: u8 = if (c.upper) '^' else ',';
                try self.ch(ch_);
                if (c.all) try self.ch(ch_);
                if (c.pattern) |p| try self.word(p);
            },
            .substring => |s| {
                try self.ch(':');
                try arith.render(self.sh, s.offset, &self.out);
                if (s.length) |l| {
                    try self.ch(':');
                    try arith.render(self.sh, l, &self.out);
                }
            },
            .transform => |c| {
                try self.ch('@');
                try self.ch(c);
            },
            .prefix_names => |k| try self.ch(if (k == .at) '@' else '*'),
        }
        try self.ch('}');
    }

    fn cond_op(self: *W, op: []const u8, c: ast.CondWord) Err!void {
        if (c.colon) try self.ch(':');
        try self.put(op);
        try self.word(c.word);
    }

    pub fn redir(self: *W, r: ast.Redirect) Err!void {
        switch (r.fd) {
            .none => {},
            .num => |n| try self.out.print(self.a, "{d}", .{n}),
            .named => |n| {
                try self.ch('{');
                try self.put(n);
                try self.ch('}');
            },
        }
        try self.put(switch (r.op) {
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
        });
        switch (r.op) {
            .in, .out, .append, .clobber, .read_write, .out_err, .append_err => {
                if (r.fd == .none and r.op != .in and r.op != .out) {} else try self.ch(' ');
                try self.word(r.target);
            },
            .heredoc, .heredoc_strip => {
                if (r.heredoc) |h| try self.put(h.delimiter);
            },
            else => try self.word(r.target),
        }
    }

    pub fn list_inline(self: *W, l: ast.List) Err!void {
        for (l.items, 0..) |it, i| {
            if (i > 0) try self.put(if (l.items[i - 1].background) " " else "; ");
            try self.and_or(it.and_or);
            if (it.background) try self.put(" &");
        }
    }

    fn and_or(self: *W, ao: ast.AndOr) Err!void {
        try self.pipeline(ao.first);
        for (ao.rest) |l| {
            try self.put(if (l.op == .and_if) " && " else " || ");
            try self.pipeline(l.pipeline);
        }
    }

    fn pipeline(self: *W, p: ast.Pipeline) Err!void {
        if (p.time != .none) try self.put(if (p.time == .time_posix) "time -p " else "time ");
        if (p.negate) try self.put("! ");
        for (p.commands, 0..) |c, i| {
            if (i > 0) try self.put(if (i - 1 < p.pipe_stderr.len and p.pipe_stderr[i - 1]) " |& " else " | ");
            try self.command(&c);
        }
    }

    pub fn simple(self: *W, s: ast.Simple) Err!void {
        var first = true;
        for (s.assigns) |a| {
            if (!first) try self.ch(' ');
            first = false;
            try self.put(a.name);
            if (a.index) |ix| {
                try self.ch('[');
                try self.word(ix);
                try self.ch(']');
            }
            try self.put(if (a.append) "+=" else "=");
            switch (a.value) {
                .scalar => |w| try self.word(w),
                .array => |elems| try self.part(.{ .array_init = elems }),
            }
        }
        for (s.words) |w| {
            if (!first) try self.ch(' ');
            first = false;
            try self.word(w);
        }
    }

    pub fn command(self: *W, c: *const ast.Command) Err!void {
        switch (c.body) {
            .simple => |s| try self.simple(s),
            .subshell => |l| {
                try self.put("( ");
                try self.list_inline(l);
                try self.put(" )");
            },
            .group => |l| {
                try self.put("{ ");
                try self.list_inline(l);
                try self.put("; }");
            },
            .if_cmd => |i| {
                for (i.clauses, 0..) |cl, n| {
                    try self.put(if (n == 0) "if " else "; elif ");
                    try self.list_inline(cl.cond);
                    try self.put("; then ");
                    try self.list_inline(cl.body);
                }
                if (i.else_body) |e| {
                    try self.put("; else ");
                    try self.list_inline(e);
                }
                try self.put("; fi");
            },
            .loop => |l| {
                try self.put(if (l.until) "until " else "while ");
                try self.list_inline(l.cond);
                try self.put("; do ");
                try self.list_inline(l.body);
                try self.put("; done");
            },
            .for_in, .select => |f| {
                try self.put(if (c.body == .select) "select " else "for ");
                try self.put(f.name);
                if (f.words) |ws| {
                    try self.put(" in");
                    for (ws) |w| {
                        try self.ch(' ');
                        try self.word(w);
                    }
                }
                try self.put("; do ");
                try self.list_inline(f.body);
                try self.put("; done");
            },
            .arith_for => |f| {
                try self.put("for ((");
                if (f.init) |n| try arith.render(self.sh, n, &self.out);
                try self.put("; ");
                if (f.cond) |n| try arith.render(self.sh, n, &self.out);
                try self.put("; ");
                if (f.step) |n| try arith.render(self.sh, n, &self.out);
                try self.put("))\ndo ");
                try self.list_inline(f.body);
                try self.put("; done");
            },
            .case => |cs| {
                try self.put("case ");
                try self.word(cs.word);
                try self.put(" in ");
                for (cs.clauses) |cl| {
                    for (cl.patterns, 0..) |p, i| {
                        if (i > 0) try self.put(" | ");
                        try self.word(p);
                    }
                    try self.put(") ");
                    try self.list_inline(cl.body);
                    try self.put(switch (cl.term) {
                        .break_ => " ;; ",
                        .fallthrough => " ;& ",
                        .test_next => " ;;& ",
                    });
                }
                try self.put("esac");
            },
            .function => |f| {
                try self.put(f.name);
                try self.put(" () ");
                try self.command(f.body);
            },
            .cond => |cd| {
                try self.put("[[ ");
                try self.cond(cd);
                try self.put(" ]]");
            },
            .arith_cmd => |n| {
                try self.put("((");
                try arith.render(self.sh, n, &self.out);
                try self.put("))");
            },
            .coproc => |cp| {
                try self.put("coproc ");
                if (cp.name) |n| {
                    try self.put(n);
                    try self.ch(' ');
                }
                try self.command(cp.body);
            },
        }
        for (c.redirs) |r| {
            try self.ch(' ');
            try self.redir(r);
        }
    }

    pub fn put_assign(self: *W, a: ast.Assign) Err!void {
        try put_assign_impl(self, a);
    }

    pub fn cond(self: *W, c: *const ast.Cond) Err!void {
        switch (c.*) {
            .word => |w| try self.word(w),
            .unary => |u| {
                try self.ch('-');
                try self.put(@tagName(u.op));
                try self.ch(' ');
                try self.word(u.arg);
            },
            .binary => |b| {
                try self.word(b.lhs);
                try self.ch(' ');
                try self.put(switch (b.op) {
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
                });
                try self.ch(' ');
                try self.word(b.rhs);
            },
            .not => |n| {
                try self.put("! ");
                try self.cond(n);
            },
            .and_ => |a| {
                try self.cond(a.lhs);
                try self.put(" && ");
                try self.cond(a.rhs);
            },
            .or_ => |a| {
                try self.cond(a.lhs);
                try self.put(" || ");
                try self.cond(a.rhs);
            },
            .group => |g| {
                try self.put("( ");
                try self.cond(g);
                try self.put(" )");
            },
        }
    }
};

pub fn word_source(sh: *Shell, w: ast.Word) Err![]const u8 {
    var wr: W = .{ .sh = sh, .a = sh.sa };
    try wr.word(w);
    return wr.out.items;
}

pub fn command_source(sh: *Shell, c: *const ast.Command) Err![]const u8 {
    var wr: W = .{ .sh = sh, .a = sh.sa };
    try wr.command(c);
    return wr.out.items;
}

pub fn list_source(sh: *Shell, l: ast.List) Err![]const u8 {
    var wr: W = .{ .sh = sh, .a = sh.sa };
    try wr.list_inline(l);
    return wr.out.items;
}

pub fn put_assign_impl(w: *W, a: ast.Assign) Err!void {
    try w.put(a.name);
    if (a.index) |ix| {
        try w.put("[");
        try w.word(ix);
        try w.put("]");
    }
    try w.put(if (a.append) "+=" else "=");
    switch (a.value) {
        .scalar => |sw| try w.word(sw),
        .array => |elems| try w.part(.{ .array_init = elems }),
    }
}

pub const Pretty = struct {
    w: W,
    indent: u32 = 0,
    heredocs: std.ArrayList(*ast.Heredoc) = .empty,

    fn put(self: *Pretty, s: []const u8) Err!void {
        try self.w.put(s);
    }

    fn pad(self: *Pretty) Err!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) try self.put("    ");
    }

    fn flush_heredocs(self: *Pretty) Err!void {
        if (self.heredocs.items.len == 0) return;
        try self.put("\n");
        for (self.heredocs.items) |h| {
            for (h.body.parts) |p| {
                switch (p) {
                    .quoted => |t| try self.put(t),
                    else => try self.w.part(p),
                }
            }
            try self.put(h.delimiter);
            try self.put("\n");
        }
        self.heredocs.clearRetainingCapacity();
    }

    fn nl(self: *Pretty) Err!void {
        if (self.heredocs.items.len > 0) {
            try self.flush_heredocs();
        } else try self.put("\n");
        try self.pad();
    }

    fn sep(self: *Pretty) Err!void {
        if (self.heredocs.items.len > 0) {
            try self.flush_heredocs();
            try self.put("\n");
            try self.pad();
            return;
        }
        try self.put(";\n");
        try self.pad();
    }

    pub fn list(self: *Pretty, l: ast.List, last_semi: bool) Err!void {
        for (l.items, 0..) |it, i| {
            try self.and_or(it.and_or);
            const last = i + 1 == l.items.len;
            if (it.background) {
                try self.put(" &");
                if (!last) try self.put(" ");
            } else if (!last) {
                try self.sep();
            }
            if (last and last_semi and !it.background) {
                if (self.heredocs.items.len == 0) try self.put(";");
            }
        }
    }

    fn and_or(self: *Pretty, ao: ast.AndOr) Err!void {
        try self.pipeline(ao.first);
        for (ao.rest) |l| {
            try self.put(if (l.op == .and_if) " && " else " || ");
            try self.pipeline(l.pipeline);
        }
    }

    fn pipeline(self: *Pretty, p: ast.Pipeline) Err!void {
        if (p.time != .none) try self.put(if (p.time == .time_posix) "time -p " else "time ");
        if (p.negate) try self.put("! ");
        for (p.commands, 0..) |*c, i| {
            try self.command(c);
            if (i + 1 < p.commands.len) {
                if (i < p.pipe_stderr.len and p.pipe_stderr[i]) try self.put(" 2>&1");
                try self.put(" | ");
            }
        }
    }

    fn redirs(self: *Pretty, rs: []const ast.Redirect) Err!void {
        for (rs) |r| {
            try self.put(" ");
            try self.redir(r);
        }
    }

    fn redir(self: *Pretty, r: ast.Redirect) Err!void {
        const w = &self.w;
        var fdbuf: [16]u8 = undefined;
        const fd_txt: []const u8 = switch (r.fd) {
            .none => "",
            .num => |n| std.fmt.bufPrint(&fdbuf, "{d}", .{n}) catch "",
            .named => "",
        };
        switch (r.fd) {
            .named => |n| {
                try w.put("{");
                try w.put(n);
                try w.put("}");
            },
            else => {},
        }
        const named = r.fd == .named;
        switch (r.op) {
            .out => {
                try w.put(fd_txt);
                try w.put("> ");
                try w.word(r.target);
            },
            .clobber => {
                try w.put(fd_txt);
                try w.put(">| ");
                try w.word(r.target);
            },
            .append => {
                try w.put(fd_txt);
                try w.put(">> ");
                try w.word(r.target);
            },
            .in => {
                try w.put(fd_txt);
                try w.put("< ");
                try w.word(r.target);
            },
            .read_write => {
                try w.put(if (fd_txt.len == 0 and !named) "0" else fd_txt);
                try w.put("<> ");
                try w.word(r.target);
            },
            .dup_out => {
                try w.put(if (fd_txt.len == 0 and !named) "1" else fd_txt);
                try w.put(">&");
                try w.word(r.target);
            },
            .dup_in => {
                try w.put(if (fd_txt.len == 0 and !named) "0" else fd_txt);
                try w.put("<&");
                try w.word(r.target);
            },
            .here_str => {
                try w.put(fd_txt);
                try w.put("<<< ");
                try w.word(r.target);
            },
            .heredoc, .heredoc_strip => {
                try w.put(fd_txt);
                try w.put(if (r.op == .heredoc) "<<" else "<<-");
                if (r.heredoc) |h| {
                    try w.put(if (h.quoted) "'" else "");
                    try w.put(h.delimiter);
                    try w.put(if (h.quoted) "'" else "");
                    try self.heredocs.append(self.w.a, h);
                }
            },
            .out_err => {
                try w.put("&> ");
                try w.word(r.target);
            },
            .append_err => {
                try w.put("&>> ");
                try w.word(r.target);
            },
        }
    }

    fn inline_list(self: *Pretty, l: ast.List) Err!void {
        try self.list(l, false);
    }

    pub fn command(self: *Pretty, c: *const ast.Command) Err!void {
        switch (c.body) {
            .simple => |s| {
                try self.w.simple(s);
            },
            .subshell => |l| {
                try self.put("( ");
                try self.list(l, false);
                try self.put(" )");
            },
            .group => |l| {
                try self.put("{ ");
                self.indent += 1;
                try self.nl();
                try self.list(l, false);
                self.indent -= 1;
                try self.nl();
                try self.put("}");
            },
            .if_cmd => |i| try self.print_if(i.clauses, 0, i.else_body),
            .loop => |l| {
                try self.put(if (l.until) "until " else "while ");
                try self.inline_list(l.cond);
                try self.put("; do");
                self.indent += 1;
                try self.nl();
                try self.list(l.body, true);
                self.indent -= 1;
                try self.nl();
                try self.put("done");
            },
            .for_in, .select => |f| {
                try self.put(if (c.body == .select) "select " else "for ");
                try self.put(f.name);
                try self.put(" in ");
                if (f.words) |ws| {
                    for (ws, 0..) |wd, i| {
                        if (i > 0) try self.put(" ");
                        try self.w.word(wd);
                    }
                } else try self.put("\"$@\"");
                try self.put(";");
                try self.nl();
                try self.put("do");
                self.indent += 1;
                try self.nl();
                try self.list(f.body, true);
                self.indent -= 1;
                try self.nl();
                try self.put("done");
            },
            .arith_for => |f| {
                try self.put("for ((");
                if (f.init) |n| try arith.render(self.w.sh, n, &self.w.out) else try self.put("1");
                try self.put("; ");
                if (f.cond) |n| try arith.render(self.w.sh, n, &self.w.out) else try self.put("1");
                try self.put("; ");
                if (f.step) |n| try arith.render(self.w.sh, n, &self.w.out) else try self.put("1");
                try self.put("))");
                try self.nl();
                try self.put("do");
                self.indent += 1;
                try self.nl();
                try self.list(f.body, true);
                self.indent -= 1;
                try self.nl();
                try self.put("done");
            },
            .case => |cs| {
                try self.put("case ");
                try self.w.word(cs.word);
                try self.put(" in ");
                self.indent += 1;
                for (cs.clauses) |cl| {
                    try self.nl();
                    for (cl.patterns, 0..) |p, i| {
                        if (i > 0) try self.put(" | ");
                        try self.w.word(p);
                    }
                    try self.put(")");
                    self.indent += 1;
                    if (cl.body.items.len == 0) {
                        try self.put("\n");
                    } else {
                        try self.nl();
                        try self.list(cl.body, false);
                    }
                    self.indent -= 1;
                    try self.nl();
                    try self.put(switch (cl.term) {
                        .break_ => ";;",
                        .fallthrough => ";&",
                        .test_next => ";;&",
                    });
                }
                self.indent -= 1;
                try self.nl();
                try self.put("esac");
            },
            .function => |f| try self.function_def(f.name, f.body, true),
            .cond => |cd| {
                try self.put("[[ ");
                try self.w.cond(cd);
                try self.put(" ]]");
            },
            .arith_cmd => |n| {
                try self.put("(( ");
                try arith.render(self.w.sh, n, &self.w.out);
                try self.put(" ))");
            },
            .coproc => |cp| {
                try self.put("coproc ");
                try self.put(cp.name orelse "COPROC");
                try self.put(" ");
                try self.command(cp.body);
            },
        }
        try self.redirs(c.redirs);
    }

    fn print_if(self: *Pretty, clauses: []const ast.IfClause, idx: usize, else_body: ?ast.List) Err!void {
        try self.put("if ");
        try self.inline_list(clauses[idx].cond);
        try self.put("; then");
        self.indent += 1;
        try self.nl();
        try self.list(clauses[idx].body, true);
        self.indent -= 1;
        try self.nl();
        if (idx + 1 < clauses.len) {
            try self.put("else");
            self.indent += 1;
            try self.nl();
            try self.print_if(clauses, idx + 1, else_body);
            try self.put(";");
            self.indent -= 1;
            try self.nl();
        } else if (else_body) |e| {
            try self.put("else");
            self.indent += 1;
            try self.nl();
            try self.list(e, true);
            self.indent -= 1;
            try self.nl();
        }
        try self.put("fi");
    }

    pub fn function_def(self: *Pretty, name: []const u8, body: *const ast.Command, nested: bool) Err!void {
        if (nested) try self.put("function ");
        try self.put(name);
        try self.put(" () ");
        try self.nl();
        const grp: ?ast.List = if (body.body == .group) body.body.group else null;
        try self.put("{ ");
        self.indent += 1;
        try self.nl();
        if (grp) |g| {
            try self.list(g, false);
        } else {
            var copy = body.*;
            copy.redirs = &.{};
            try self.command(&copy);
        }
        self.indent -= 1;
        try self.nl();
        try self.put("}");
        try self.redirs(body.redirs);
    }
};

pub fn function_text(sh: *Shell, name: []const u8, body: *const ast.Command, out: *std.ArrayList(u8)) Err!void {
    var p: Pretty = .{ .w = .{ .sh = sh, .a = sh.sa } };
    try p.function_def(name, body, false);
    try p.flush_heredocs();
    try p.put("\n");
    try out.appendSlice(sh.sa, p.w.out.items);
}

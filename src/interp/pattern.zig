const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    extglob: bool = true,
    nocase: bool = false,
    dot_literal: bool = false,
};

pub fn is_meta_char(c: u8) bool {
    return switch (c) {
        '*', '?', '[', '\\' => true,
        else => false,
    };
}

pub fn has_meta(p: []const u8, extglob: bool) bool {
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        switch (p[i]) {
            '*', '?', '[' => {
                if (p[i] == '[' and !has_close_bracket(p, i)) continue;
                return true;
            },
            '+', '@', '!' => if (extglob and i + 1 < p.len and p[i + 1] == '(') return true,
            '\\' => i += 1,
            else => {},
        }
    }
    return false;
}

fn has_close_bracket(p: []const u8, open: usize) bool {
    return bracket_end(p, open) != null;
}

fn bracket_end(p: []const u8, open: usize) ?usize {
    var i = open + 1;
    if (i < p.len and (p[i] == '!' or p[i] == '^')) i += 1;
    if (i < p.len and p[i] == ']') i += 1;
    while (i < p.len) {
        const c = p[i];
        if (c == ']') return i;
        if (c == '\\' and i + 1 < p.len) {
            i += 2;
            continue;
        }
        if (c == '[' and i + 1 < p.len and (p[i + 1] == ':' or p[i + 1] == '=' or p[i + 1] == '.')) {
            const d = p[i + 1];
            var j = i + 2;
            while (j + 1 < p.len) : (j += 1) {
                if (p[j] == d and p[j + 1] == ']') break;
            } else {
                i += 1;
                continue;
            }
            i = j + 2;
            continue;
        }
        i += 1;
    }
    return null;
}

pub fn unescape(a: Allocator, p: []const u8) Allocator.Error![]u8 {
    if (std.mem.findScalar(u8, p, '\\') == null) return a.dupe(u8, p);
    var out = try a.alloc(u8, p.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '\\' and i + 1 < p.len) i += 1;
        out[n] = p[i];
        n += 1;
    }
    return a.realloc(out, n);
}

pub fn escape_into(out: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '*', '?', '[', ']', '\\', '(', ')', '|', '!', '+', '@', '{', '}', '-', '^', '~', '#' => try out.append(a, '\\'),
            else => {},
        }
        try out.append(a, c);
    }
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn class_match(name: []const u8, c: u8) bool {
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(c);
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(c);
    if (std.mem.eql(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "punct")) return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
    if (std.mem.eql(u8, name, "print")) return std.ascii.isPrint(c);
    if (std.mem.eql(u8, name, "graph")) return std.ascii.isPrint(c) and c != ' ';
    if (std.mem.eql(u8, name, "cntrl")) return std.ascii.isControl(c);
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    if (std.mem.eql(u8, name, "word")) return std.ascii.isAlphanumeric(c) or c == '_';
    if (std.mem.eql(u8, name, "ascii")) return c < 128;
    return false;
}

fn bracket_match(p: []const u8, open: usize, close: usize, c: u8, nocase: bool) bool {
    var i = open + 1;
    var neg = false;
    if (i < close and (p[i] == '!' or p[i] == '^')) {
        neg = true;
        i += 1;
    }
    var matched = false;
    while (i < close) {
        var lo = p[i];
        if (lo == '[' and i + 1 < close and (p[i + 1] == ':' or p[i + 1] == '=' or p[i + 1] == '.')) {
            const d = p[i + 1];
            var j = i + 2;
            while (j + 1 < close + 1) : (j += 1) {
                if (p[j] == d and p[j + 1] == ']') break;
            } else {
                j = p.len;
            }
            if (j + 1 <= close) {
                const name = p[i + 2 .. j];
                if (d == ':') {
                    if (class_match(name, c)) matched = true;
                    if (nocase and (class_match(name, lower(c)) or class_match(name, std.ascii.toUpper(c)))) matched = true;
                } else if (name.len == 1 and name[0] == c) matched = true;
                i = j + 2;
                continue;
            }
        }
        if (lo == '\\' and i + 1 < close) {
            i += 1;
            lo = p[i];
        }
        i += 1;
        if (i + 1 < close and p[i] == '-') {
            var hi = p[i + 1];
            var adv: usize = 2;
            if (hi == '\\' and i + 2 < close) {
                hi = p[i + 2];
                adv = 3;
            }
            i += adv;
            if (nocase) {
                const lc = lower(c);
                const uc = std.ascii.toUpper(c);
                if ((c >= lo and c <= hi) or (lc >= lo and lc <= hi) or (uc >= lo and uc <= hi)) matched = true;
            } else if (c >= lo and c <= hi) matched = true;
        } else {
            if (lo == c or (nocase and lower(lo) == lower(c))) matched = true;
        }
    }
    return matched != neg;
}

fn is_ext_op(c: u8) bool {
    return c == '?' or c == '*' or c == '+' or c == '@' or c == '!';
}

fn group_end(p: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < p.len) : (i += 1) {
        switch (p[i]) {
            '\\' => i += 1,
            '[' => {
                if (bracket_end(p, i)) |e| i = e;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

pub const Matcher = struct {
    a: Allocator,
    o: Opts,
    depth: u32 = 0,

    pub fn full(self: *Matcher, p: []const u8, t: []const u8) bool {
        return self.mt(p, t);
    }

    fn mt(self: *Matcher, p: []const u8, t: []const u8) bool {
        var pi: usize = 0;
        var ti: usize = 0;
        var star_p: ?usize = null;
        var star_t: usize = 0;
        const ext = self.o.extglob;
        while (true) {
            var advanced = false;
            if (pi < p.len) {
                const c = p[pi];
                if (c == '*' and !(ext and pi + 1 < p.len and p[pi + 1] == '(')) {
                    while (pi < p.len and p[pi] == '*' and !(ext and pi + 1 < p.len and p[pi + 1] == '(')) pi += 1;
                    star_p = pi;
                    star_t = ti;
                    if (pi == p.len) return true;
                    continue;
                }
                if (ext and is_ext_op(c) and pi + 1 < p.len and p[pi + 1] == '(') {
                    if (group_end(p, pi + 1)) |ge| {
                        if (self.group(p, pi, ge, t[ti..])) return true;
                        advanced = false;
                        pi = p.len + 1;
                    }
                }
                if (pi <= p.len and pi < p.len and ti < t.len) {
                    const tc = t[ti];
                    switch (c) {
                        '?' => {
                            pi += 1;
                            ti += 1;
                            advanced = true;
                        },
                        '[' => {
                            if (bracket_end(p, pi)) |ce| {
                                if (bracket_match(p, pi, ce, tc, self.o.nocase)) {
                                    pi = ce + 1;
                                    ti += 1;
                                    advanced = true;
                                }
                            } else if (tc == '[') {
                                pi += 1;
                                ti += 1;
                                advanced = true;
                            }
                        },
                        '\\' => {
                            const lit = if (pi + 1 < p.len) p[pi + 1] else '\\';
                            if (lit == tc or (self.o.nocase and lower(lit) == lower(tc))) {
                                pi += if (pi + 1 < p.len) 2 else 1;
                                ti += 1;
                                advanced = true;
                            }
                        },
                        else => {
                            if (c == tc or (self.o.nocase and lower(c) == lower(tc))) {
                                pi += 1;
                                ti += 1;
                                advanced = true;
                            }
                        },
                    }
                }
            } else if (ti == t.len) return true;
            if (advanced) continue;
            if (star_p) |sp| {
                star_t += 1;
                if (star_t > t.len) return false;
                pi = sp;
                ti = star_t;
                continue;
            }
            return false;
        }
    }

    fn group(self: *Matcher, p: []const u8, start: usize, close: usize, t: []const u8) bool {
        if (self.depth > 100) return false;
        self.depth += 1;
        defer self.depth -= 1;
        const op = p[start];
        const rest = p[close + 1 ..];
        const body = p[start + 2 .. close];
        switch (op) {
            '!' => {
                var k: usize = 0;
                while (k <= t.len) : (k += 1) {
                    if (self.any_alt(body, t[0..k])) continue;
                    if (self.mt(rest, t[k..])) return true;
                }
                return false;
            },
            '?', '@' => {
                if (op == '?' and self.mt(rest, t)) return true;
                return self.alts_then(body, rest, t);
            },
            '*', '+' => {
                if (op == '*' and self.mt(rest, t)) return true;
                return self.repeat(body, p[close + 1 ..], t, 0);
            },
            else => return false,
        }
    }

    fn any_alt(self: *Matcher, body: []const u8, t: []const u8) bool {
        var parts = alt_iter(body);
        while (parts.next()) |alt| {
            if (self.mt(alt, t)) return true;
        }
        return false;
    }

    fn alts_then(self: *Matcher, body: []const u8, rest: []const u8, t: []const u8) bool {
        var parts = alt_iter(body);
        while (parts.next()) |alt| {
            const joined = self.a.alloc(u8, alt.len + rest.len) catch return false;
            defer self.a.free(joined);
            @memcpy(joined[0..alt.len], alt);
            @memcpy(joined[alt.len..], rest);
            if (self.mt(joined, t)) return true;
        }
        return false;
    }

    fn repeat(self: *Matcher, body: []const u8, rest: []const u8, t: []const u8, n: u32) bool {
        if (n > 0 and self.mt(rest, t)) return true;
        if (t.len == 0) return false;
        var parts = alt_iter(body);
        while (parts.next()) |alt| {
            var k: usize = 1;
            while (k <= t.len) : (k += 1) {
                if (self.mt(alt, t[0..k]) and self.repeat(body, rest, t[k..], n + 1)) return true;
            }
        }
        return false;
    }
};

const AltIter = struct {
    s: []const u8,
    i: usize = 0,
    done: bool = false,

    fn next(self: *AltIter) ?[]const u8 {
        if (self.done) return null;
        const start = self.i;
        var depth: usize = 0;
        var i = self.i;
        while (i < self.s.len) : (i += 1) {
            switch (self.s[i]) {
                '\\' => i += 1,
                '[' => {
                    if (bracket_end(self.s, i)) |e| i = e;
                },
                '(' => depth += 1,
                ')' => depth -|= 1,
                '|' => if (depth == 0) {
                    self.i = i + 1;
                    return self.s[start..i];
                },
                else => {},
            }
        }
        self.done = true;
        return self.s[start..];
    }
};

fn alt_iter(s: []const u8) AltIter {
    return .{ .s = s };
}

pub fn match(a: Allocator, p: []const u8, t: []const u8, o: Opts) bool {
    if (o.dot_literal and t.len > 0 and t[0] == '.') {
        if (p.len == 0) return false;
        if (!(p[0] == '.' or (p[0] == '\\' and p.len > 1 and p[1] == '.'))) return false;
    }
    var m: Matcher = .{ .a = a, .o = o };
    return m.full(p, t);
}

pub fn match_simple(p: []const u8, t: []const u8) bool {
    return match(std.heap.page_allocator, p, t, .{});
}

test "basic globs" {
    const a = std.testing.allocator;
    try std.testing.expect(match(a, "*.txt", "a.txt", .{}));
    try std.testing.expect(!match(a, "*.txt", "a.txx", .{}));
    try std.testing.expect(match(a, "a?c", "abc", .{}));
    try std.testing.expect(match(a, "[a-c]x", "bx", .{}));
    try std.testing.expect(!match(a, "[!a-c]x", "bx", .{}));
    try std.testing.expect(match(a, "[[:digit:]]*", "1abc", .{}));
    try std.testing.expect(match(a, "*", "", .{}));
    try std.testing.expect(match(a, "a*b*c", "aXXbYYc", .{}));
    try std.testing.expect(!match(a, "a*b*c", "aXXbYY", .{}));
    try std.testing.expect(match(a, "\\*", "*", .{}));
    try std.testing.expect(!match(a, "\\*", "a", .{}));
}

test "extglob" {
    const a = std.testing.allocator;
    try std.testing.expect(match(a, "@(foo|bar).c", "foo.c", .{}));
    try std.testing.expect(!match(a, "@(foo|bar).c", "baz.c", .{}));
    try std.testing.expect(match(a, "*(a|b)c", "ababc", .{}));
    try std.testing.expect(match(a, "+(a)", "aaa", .{}));
    try std.testing.expect(!match(a, "+(a)", "", .{}));
    try std.testing.expect(match(a, "?(x)y", "y", .{}));
    try std.testing.expect(match(a, "!(a*)", "b", .{}));
    try std.testing.expect(!match(a, "!(a*)", "ab", .{}));
    try std.testing.expect(match(a, "!(*.c)", "x.h", .{}));
}

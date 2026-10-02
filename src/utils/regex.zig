const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");

pub const ByteSet = struct {
    bits: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn has(self: ByteSet, b: u8) bool {
        return (self.bits[b >> 6] >> @intCast(b & 63)) & 1 != 0;
    }

    pub fn add(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] |= @as(u64, 1) << @intCast(b & 63);
    }

    pub fn remove(self: *ByteSet, b: u8) void {
        self.bits[b >> 6] &= ~(@as(u64, 1) << @intCast(b & 63));
    }

    pub fn addRange(self: *ByteSet, lo: u8, hi: u8) void {
        var c: usize = lo;
        while (c <= hi) : (c += 1) self.add(@intCast(c));
    }

    pub fn negate(self: *ByteSet) void {
        for (&self.bits) |*w| w.* = ~w.*;
    }

    pub fn unite(self: *ByteSet, other: ByteSet) void {
        for (&self.bits, other.bits) |*a, b| a.* |= b;
    }

    pub fn isEmpty(self: ByteSet) bool {
        return (self.bits[0] | self.bits[1] | self.bits[2] | self.bits[3]) == 0;
    }

    pub fn count(self: ByteSet) usize {
        var n: usize = 0;
        for (self.bits) |w| n += @popCount(w);
        return n;
    }

    pub fn eql(self: ByteSet, other: ByteSet) bool {
        return std.mem.eql(u64, &self.bits, &other.bits);
    }

    pub fn single(self: ByteSet) ?u8 {
        if (self.count() != 1) return null;
        for (self.bits, 0..) |w, i| if (w != 0) return @intCast(i * 64 + @ctz(w));
        return null;
    }
};

pub const Syntax = enum { bre, ere, fixed, rust };

pub const Options = struct {
    syntax: Syntax = .bre,
    icase: bool = false,
    utf8: bool = false,
    line_mode: bool = true,
    whole_line: bool = false,
};

pub const CompileError = error{ Unsupported, Invalid, OutOfMemory };

const Assert = enum { bol, eol, word_b, nword_b, word_start, word_end };

const Node = union(enum) {
    empty,
    set: ByteSet,
    cat: []const *Node,
    alt: []const *Node,
    repeat: struct { sub: *Node, min: u32, max: u32, greedy: bool },
    group: struct { sub: *Node, idx: u32 },
    assert: Assert,
};

const inf: u32 = std.math.maxInt(u32);

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    opts: Options,
    ngroups: u32 = 0,
    depth: u32 = 0,
    has_word_assert: bool = false,
    has_assert: bool = false,
    sensitive: bool = false,

    fn node(self: *Parser, n: Node) CompileError!*Node {
        const p = try self.arena.create(Node);
        p.* = n;
        return p;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn lookingAt(self: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    fn atAltSep(self: *Parser) bool {
        return switch (self.opts.syntax) {
            .ere, .rust => self.peek() == '|',
            .bre => self.lookingAt("\\|"),
            .fixed => false,
        };
    }

    fn atClose(self: *Parser) bool {
        return switch (self.opts.syntax) {
            .ere, .rust => self.peek() == ')',
            .bre => self.lookingAt("\\)"),
            .fixed => false,
        };
    }

    fn parseAlt(self: *Parser) CompileError!*Node {
        var alts: std.ArrayList(*Node) = .empty;
        while (true) {
            const c = try self.parseCat();
            try alts.append(self.arena, c);
            if (self.atAltSep()) {
                self.pos += if (self.opts.syntax == .bre) 2 else 1;
                continue;
            }
            break;
        }
        if (alts.items.len == 1) return alts.items[0];
        return self.node(.{ .alt = alts.items });
    }

    fn parseCat(self: *Parser) CompileError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        const bre = self.opts.syntax == .bre;
        var first = true;
        while (self.pos < self.src.len) {
            if (self.atAltSep()) break;
            if (self.atClose()) {
                if (self.depth > 0) break;
                return error.Invalid;
            }
            var atom = (try self.parseAtom(first, items.items.len == 1 and bre and isBolAnchor(items.items[0]))) orelse continue;
            atom = try self.parseQuantifiers(atom);
            try items.append(self.arena, atom);
            first = false;
        }
        if (items.items.len == 0) return self.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.node(.{ .cat = items.items });
    }

    fn isBolAnchor(n: *Node) bool {
        return n.* == .assert and n.assert == .bol;
    }

    fn literalNode(self: *Parser, c: u8) CompileError!*Node {
        var s: ByteSet = .{};
        s.add(c);
        if (self.opts.icase and std.ascii.isAlphabetic(c)) {
            self.sensitive = true;
            s.add(std.ascii.toLower(c));
            s.add(std.ascii.toUpper(c));
        }
        return self.node(.{ .set = s });
    }

    fn literalCp(self: *Parser) CompileError!*Node {
        const c = self.src[self.pos];
        if (c < 0x80 or !self.opts.utf8) {
            self.pos += 1;
            return self.literalNode(c);
        }
        const dec = uniDecode(self.src[self.pos..]);
        const n = dec orelse {
            self.pos += 1;
            return self.literalNode(c);
        };
        if (self.opts.icase) return error.Unsupported;
        var items: std.ArrayList(*Node) = .empty;
        for (self.src[self.pos..][0..n]) |b| {
            var s: ByteSet = .{};
            s.add(b);
            try items.append(self.arena, try self.node(.{ .set = s }));
        }
        self.pos += n;
        return self.node(.{ .cat = items.items });
    }

    fn anyNode(self: *Parser) CompileError!*Node {
        if (!self.opts.utf8) {
            var s: ByteSet = .{};
            s.negate();
            if (self.opts.line_mode) s.remove('\n');
            return self.node(.{ .set = s });
        }
        return self.utf8Any(.{});
    }

    fn utf8Any(self: *Parser, ascii_excluded: ByteSet) CompileError!*Node {
        var ascii: ByteSet = .{};
        ascii.addRange(0, 0x7f);
        for (0..4) |i| ascii.bits[i] &= ~ascii_excluded.bits[i];
        if (self.opts.line_mode) ascii.remove('\n');
        const multi = try self.utf8Multi();
        const a = try self.node(.{ .set = ascii });
        const alts = try self.arena.alloc(*Node, 2);
        alts[0] = a;
        alts[1] = multi;
        return self.node(.{ .alt = alts });
    }

    fn rangeNode(self: *Parser, lo: u8, hi: u8) CompileError!*Node {
        var s: ByteSet = .{};
        s.addRange(lo, hi);
        return self.node(.{ .set = s });
    }

    fn seq(self: *Parser, parts: []const [2]u8) CompileError!*Node {
        const items = try self.arena.alloc(*Node, parts.len);
        for (parts, 0..) |p, i| items[i] = try self.rangeNode(p[0], p[1]);
        return self.node(.{ .cat = items });
    }

    fn utf8Multi(self: *Parser) CompileError!*Node {
        const alts = try self.arena.alloc(*Node, 7);
        alts[0] = try self.seq(&.{ .{ 0xc2, 0xdf }, .{ 0x80, 0xbf } });
        alts[1] = try self.seq(&.{ .{ 0xe0, 0xe0 }, .{ 0xa0, 0xbf }, .{ 0x80, 0xbf } });
        alts[2] = try self.seq(&.{ .{ 0xe1, 0xec }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf } });
        alts[3] = try self.seq(&.{ .{ 0xed, 0xed }, .{ 0x80, 0x9f }, .{ 0x80, 0xbf } });
        alts[4] = try self.seq(&.{ .{ 0xee, 0xef }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf } });
        alts[5] = try self.seq(&.{ .{ 0xf0, 0xf0 }, .{ 0x90, 0xbf }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf } });
        const tail = try self.arena.alloc(*Node, 2);
        tail[0] = try self.seq(&.{ .{ 0xf1, 0xf7 }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf } });
        tail[1] = try self.seq(&.{ .{ 0xf8, 0xfb }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf }, .{ 0x80, 0xbf } });
        alts[6] = try self.node(.{ .alt = tail });
        return self.node(.{ .alt = alts });
    }

    fn assertNode(self: *Parser, a: Assert) CompileError!*Node {
        self.has_assert = true;
        switch (a) {
            .word_b, .nword_b, .word_start, .word_end => {
                self.has_word_assert = true;
                self.sensitive = true;
            },
            else => {},
        }
        return self.node(.{ .assert = a });
    }

    fn classSet(name: []const u8, set: *ByteSet) bool {
        const Cl = enum { alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit };
        const cl = std.meta.stringToEnum(Cl, name) orelse return false;
        var c: usize = 0;
        while (c < 128) : (c += 1) {
            const b: u8 = @intCast(c);
            const ok = switch (cl) {
                .alnum => std.ascii.isAlphanumeric(b),
                .alpha => std.ascii.isAlphabetic(b),
                .blank => b == ' ' or b == '\t',
                .cntrl => b < 32 or b == 127,
                .digit => std.ascii.isDigit(b),
                .graph => b > 32 and b < 127,
                .lower => std.ascii.isLower(b),
                .print => b >= 32 and b < 127,
                .punct => b > 32 and b < 127 and !std.ascii.isAlphanumeric(b),
                .space => (b >= 9 and b <= 13) or b == 32,
                .upper => std.ascii.isUpper(b),
                .xdigit => std.ascii.isHex(b),
            };
            if (ok) set.add(b);
        }
        return true;
    }

    fn parseBracket(self: *Parser) CompileError!*Node {
        self.pos += 1;
        var neg = false;
        if (self.peek() == '^') {
            neg = true;
            self.pos += 1;
        }
        var set: ByteSet = .{};
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.Invalid;
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            if (c == '[' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == ':' or self.src[self.pos + 1] == '=' or self.src[self.pos + 1] == '.')) {
                const kind = self.src[self.pos + 1];
                const rest = self.src[self.pos + 2 ..];
                const close = std.mem.find(u8, rest, &[_]u8{ kind, ']' }) orelse return error.Invalid;
                const name = rest[0..close];
                self.pos += 2 + close + 2;
                if (kind == ':') {
                    if (!classSet(name, &set)) return error.Invalid;
                    if (!std.mem.eql(u8, name, "digit") and !std.mem.eql(u8, name, "xdigit")) self.sensitive = true;
                    if (self.opts.icase and (std.mem.eql(u8, name, "upper") or std.mem.eql(u8, name, "lower"))) {
                        _ = classSet("alpha", &set);
                    }
                } else {
                    if (name.len != 1 or name[0] >= 0x80) return error.Unsupported;
                    set.add(name[0]);
                }
                if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') return error.Invalid;
                continue;
            }
            if (c >= 0x80 and self.opts.utf8) return error.Unsupported;
            self.pos += 1;
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1;
                const hi = self.src[self.pos];
                if (hi == '[' and self.pos + 1 < self.src.len and (self.src[self.pos + 1] == '.' or self.src[self.pos + 1] == '=' or self.src[self.pos + 1] == ':')) return error.Unsupported;
                if (hi >= 0x80 and self.opts.utf8) return error.Unsupported;
                self.pos += 1;
                if (hi < c) return error.Invalid;
                set.addRange(c, hi);
            } else set.add(c);
        }
        if (self.opts.icase) {
            self.sensitive = true;
            var extra: ByteSet = .{};
            var b: usize = 'a';
            while (b <= 'z') : (b += 1) {
                const lo: u8 = @intCast(b);
                const up = std.ascii.toUpper(lo);
                if (set.has(lo) or set.has(up)) {
                    extra.add(lo);
                    extra.add(up);
                }
            }
            set.unite(extra);
        }
        if (neg) {
            if (self.opts.utf8) {
                var ascii_excl: ByteSet = set;
                for (128..256) |i| ascii_excl.remove(@intCast(i));
                return self.utf8Any(ascii_excl);
            }
            set.negate();
        }
        if (self.opts.line_mode) set.remove('\n');
        if (set.isEmpty()) return self.node(.{ .set = set });
        return self.node(.{ .set = set });
    }

    fn parseGroup(self: *Parser) CompileError!*Node {
        const bre = self.opts.syntax == .bre;
        self.pos += if (bre) 2 else 1;
        var capture = true;
        if (self.opts.syntax == .rust and self.lookingAt("?")) {
            if (self.lookingAt("?:")) {
                self.pos += 2;
                capture = false;
            } else return error.Unsupported;
        }
        self.depth += 1;
        var idx: u32 = 0;
        if (capture) {
            self.ngroups += 1;
            idx = self.ngroups;
        }
        const inner = try self.parseAlt();
        self.depth -= 1;
        if (!self.atClose()) return error.Invalid;
        self.pos += if (bre) 2 else 1;
        if (!capture) return inner;
        return self.node(.{ .group = .{ .sub = inner, .idx = idx } });
    }

    fn parseAtom(self: *Parser, first: bool, after_bol: bool) CompileError!?*Node {
        const c = self.src[self.pos];
        const syn = self.opts.syntax;
        if (syn == .fixed) return try self.literalCp();
        switch (c) {
            '.' => {
                self.pos += 1;
                return try self.anyNode();
            },
            '[' => return try self.parseBracket(),
            '*' => {
                if (syn == .bre) {
                    if (first or after_bol) {
                        self.pos += 1;
                        return try self.literalNode('*');
                    }
                    return error.Unsupported;
                }
                return error.Unsupported;
            },
            '+', '?' => {
                if (syn == .bre) {
                    self.pos += 1;
                    return try self.literalNode(c);
                }
                return error.Unsupported;
            },
            '{' => {
                if (syn == .bre) {
                    self.pos += 1;
                    return try self.literalNode(c);
                }
                if (self.validIntervalAt(self.pos)) return error.Unsupported;
                self.pos += 1;
                return try self.literalNode(c);
            },
            '(' => {
                if (syn == .bre) {
                    self.pos += 1;
                    return try self.literalNode(c);
                }
                return try self.parseGroup();
            },
            ')' => {
                self.pos += 1;
                return try self.literalNode(c);
            },
            '|' => {
                self.pos += 1;
                return try self.literalNode(c);
            },
            '^' => {
                if (syn == .bre) {
                    if (first) {
                        self.pos += 1;
                        return try self.assertNode(.bol);
                    }
                    self.pos += 1;
                    return try self.literalNode('^');
                }
                self.pos += 1;
                return try self.assertNode(.bol);
            },
            '$' => {
                if (syn == .bre) {
                    const rest = self.src[self.pos + 1 ..];
                    if (rest.len == 0 or std.mem.startsWith(u8, rest, "\\)") or std.mem.startsWith(u8, rest, "\\|")) {
                        self.pos += 1;
                        return try self.assertNode(.eol);
                    }
                    self.pos += 1;
                    return try self.literalNode('$');
                }
                self.pos += 1;
                return try self.assertNode(.eol);
            },
            '\\' => return try self.parseEscape(),
            else => return try self.literalCp(),
        }
    }

    fn validIntervalAt(self: *Parser, at: usize) bool {
        const s = self.src[at..];
        if (s.len == 0 or s[0] != '{') return false;
        var i: usize = 1;
        var d1: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) d1 += 1;
        if (i < s.len and s[i] == '}') return d1 > 0;
        if (i < s.len and s[i] == ',') {
            i += 1;
            var d2: usize = 0;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) d2 += 1;
            if (i < s.len and s[i] == '}') return d1 > 0 or d2 > 0;
        }
        return false;
    }

    fn parseEscape(self: *Parser) CompileError!*Node {
        if (self.pos + 1 >= self.src.len) return error.Invalid;
        const e = self.src[self.pos + 1];
        const syn = self.opts.syntax;
        if (syn == .bre and e == '(') return try self.parseGroup();
        switch (e) {
            'w', 'W' => {
                self.sensitive = true;
                var s: ByteSet = .{};
                var b: usize = 0;
                while (b < 128) : (b += 1) if (isWordByte(@intCast(b))) s.add(@intCast(b));
                if (e == 'W') {
                    s.negate();
                    if (self.opts.utf8) {
                        var ascii_excl: ByteSet = .{};
                        b = 0;
                        while (b < 128) : (b += 1) if (isWordByte(@intCast(b))) ascii_excl.add(@intCast(b));
                        self.pos += 2;
                        return self.utf8Any(ascii_excl);
                    }
                }
                if (self.opts.line_mode) s.remove('\n');
                self.pos += 2;
                self.has_word_assert = true;
                return self.node(.{ .set = s });
            },
            's', 'S' => {
                self.sensitive = true;
                var s: ByteSet = .{};
                s.addRange(9, 13);
                s.add(' ');
                if (e == 'S') {
                    if (self.opts.utf8) {
                        self.pos += 2;
                        return self.utf8Any(s);
                    }
                    s.negate();
                }
                if (self.opts.line_mode) s.remove('\n');
                self.pos += 2;
                return self.node(.{ .set = s });
            },
            'b' => {
                self.pos += 2;
                return self.assertNode(.word_b);
            },
            'B' => {
                self.pos += 2;
                return self.assertNode(.nword_b);
            },
            '<' => {
                self.pos += 2;
                return self.assertNode(.word_start);
            },
            '>' => {
                self.pos += 2;
                return self.assertNode(.word_end);
            },
            '`' => {
                self.pos += 2;
                return self.assertNode(.bol);
            },
            '\'' => {
                self.pos += 2;
                return self.assertNode(.eol);
            },
            '1'...'9' => return error.Unsupported,
            else => {},
        }
        if (std.ascii.isAlphanumeric(e)) return error.Unsupported;
        if (e >= 0x80) return error.Unsupported;
        switch (syn) {
            .bre => switch (e) {
                '{', '}', '|', '+', '?', ')' => return error.Unsupported,
                else => {},
            },
            .ere => {},
            else => {},
        }
        self.pos += 2;
        return self.literalNode(e);
    }

    fn parseQuantifiers(self: *Parser, atom_in: *Node) CompileError!*Node {
        var atom = atom_in;
        const bre = self.opts.syntax == .bre;
        if (bre and atom.* == .assert and (atom.assert == .bol or atom.assert == .eol)) return atom;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            var min: u32 = 0;
            var max: u32 = inf;
            var consumed: usize = 0;
            if (c == '*') {
                consumed = 1;
            } else if (!bre and c == '+') {
                min = 1;
                consumed = 1;
            } else if (!bre and c == '?') {
                max = 1;
                consumed = 1;
            } else if (bre and self.lookingAt("\\+")) {
                min = 1;
                consumed = 2;
            } else if (bre and self.lookingAt("\\?")) {
                max = 1;
                consumed = 2;
            } else if (bre and self.lookingAt("\\{")) {
                const iv = try self.parseInterval(self.pos + 2, true);
                min = iv.min;
                max = iv.max;
                consumed = iv.end - self.pos;
            } else if (!bre and c == '{' and self.validIntervalAt(self.pos)) {
                const iv = try self.parseInterval(self.pos + 1, false);
                min = iv.min;
                max = iv.max;
                consumed = iv.end - self.pos;
            } else break;
            self.pos += consumed;
            var greedy = true;
            if (self.opts.syntax == .rust and self.peek() == '?') {
                greedy = false;
                self.pos += 1;
            }
            atom = try self.node(.{ .repeat = .{ .sub = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    const Interval = struct { min: u32, max: u32, end: usize };

    fn parseInterval(self: *Parser, start: usize, bre: bool) CompileError!Interval {
        var i = start;
        var n1: u32 = 0;
        var d1: usize = 0;
        while (i < self.src.len and std.ascii.isDigit(self.src[i])) : (i += 1) {
            n1 = std.math.mul(u32, n1, 10) catch return error.Unsupported;
            n1 = std.math.add(u32, n1, self.src[i] - '0') catch return error.Unsupported;
            d1 += 1;
        }
        var n2: u32 = n1;
        var has_comma = false;
        var d2: usize = 0;
        if (i < self.src.len and self.src[i] == ',') {
            has_comma = true;
            i += 1;
            n2 = inf;
            var v: u32 = 0;
            while (i < self.src.len and std.ascii.isDigit(self.src[i])) : (i += 1) {
                v = std.math.mul(u32, v, 10) catch return error.Unsupported;
                v = std.math.add(u32, v, self.src[i] - '0') catch return error.Unsupported;
                d2 += 1;
            }
            if (d2 > 0) n2 = v;
        }
        if (d1 == 0 and d2 == 0) return error.Unsupported;
        const closer: []const u8 = if (bre) "\\}" else "}";
        if (!std.mem.startsWith(u8, self.src[i..], closer)) return error.Unsupported;
        const min: u32 = if (d1 > 0) n1 else 0;
        const max: u32 = if (has_comma) n2 else n1;
        if (max != inf and max < min) return error.Unsupported;
        if (min > 1000 or (max != inf and max > 1000)) return error.Unsupported;
        return .{ .min = min, .max = max, .end = i + closer.len };
    }
};

fn uniDecode(s: []const u8) ?usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n > s.len) return null;
    _ = std.unicode.utf8Decode(s[0..n]) catch return null;
    return n;
}

const NKind = enum(u8) { byteset, split, jump, assert, save, match };

const NState = struct {
    kind: NKind,
    out: u32 = 0,
    out1: u32 = 0,
    arg: u32 = 0,
};

const Nfa = struct {
    states: std.ArrayList(NState) = .empty,
    sets: std.ArrayList(ByteSet) = .empty,
    start: u32 = 0,
    ngroups: u32 = 0,

    fn deinit(self: *Nfa, alloc: Allocator) void {
        self.states.deinit(alloc);
        self.sets.deinit(alloc);
    }

    fn add(self: *Nfa, alloc: Allocator, s: NState) CompileError!u32 {
        if (self.states.items.len >= 400_000) return error.Unsupported;
        try self.states.append(alloc, s);
        return @intCast(self.states.items.len - 1);
    }

    fn setId(self: *Nfa, alloc: Allocator, s: ByteSet) CompileError!u32 {
        for (self.sets.items, 0..) |e, i| if (e.eql(s)) return @intCast(i);
        try self.sets.append(alloc, s);
        return @intCast(self.sets.items.len - 1);
    }
};

const Hole = struct { state: u32, which: u1 };
const Holes = std.ArrayList(Hole);
const Frag = struct { start: u32, holes: Holes };

const Compiler = struct {
    alloc: Allocator,
    tmp: Allocator,
    nfa: *Nfa,

    fn patch(self: *Compiler, holes: []const Hole, target: u32) void {
        for (holes) |h| {
            if (h.which == 0) self.nfa.states.items[h.state].out = target else self.nfa.states.items[h.state].out1 = target;
        }
    }

    fn single(self: *Compiler, st: NState) CompileError!Frag {
        const s = try self.nfa.add(self.alloc, st);
        var h: Holes = .empty;
        try h.append(self.tmp, .{ .state = s, .which = 0 });
        return .{ .start = s, .holes = h };
    }

    fn chain(self: *Compiler, acc: *?Frag, f: Frag) void {
        if (acc.*) |*a| {
            self.patch(a.holes.items, f.start);
            a.holes = f.holes;
        } else acc.* = f;
    }

    fn compile(self: *Compiler, n: *const Node) CompileError!Frag {
        switch (n.*) {
            .empty => return self.single(.{ .kind = .jump }),
            .set => |set| return self.single(.{ .kind = .byteset, .arg = try self.nfa.setId(self.alloc, set) }),
            .assert => |a| return self.single(.{ .kind = .assert, .arg = @intFromEnum(a) }),
            .cat => |items| {
                var acc: ?Frag = null;
                for (items) |it| self.chain(&acc, try self.compile(it));
                return acc.?;
            },
            .alt => |items| {
                var frag = try self.compile(items[items.len - 1]);
                var i = items.len - 1;
                while (i > 0) {
                    i -= 1;
                    const left = try self.compile(items[i]);
                    const sp = try self.nfa.add(self.alloc, .{ .kind = .split, .out = left.start, .out1 = frag.start });
                    var holes = left.holes;
                    try holes.appendSlice(self.tmp, frag.holes.items);
                    frag = .{ .start = sp, .holes = holes };
                }
                return frag;
            },
            .group => |g| {
                const open = try self.nfa.add(self.alloc, .{ .kind = .save, .arg = g.idx * 2 });
                const inner = try self.compile(g.sub);
                self.nfa.states.items[open].out = inner.start;
                const close = try self.nfa.add(self.alloc, .{ .kind = .save, .arg = g.idx * 2 + 1 });
                self.patch(inner.holes.items, close);
                var h: Holes = .empty;
                try h.append(self.tmp, .{ .state = close, .which = 0 });
                return .{ .start = open, .holes = h };
            },
            .repeat => |r| return self.compileRepeat(r.sub, r.min, r.max, r.greedy),
        }
    }

    fn compileRepeat(self: *Compiler, sub: *const Node, min: u32, max: u32, greedy: bool) CompileError!Frag {
        var acc: ?Frag = null;
        var i: u32 = 0;
        while (i < min) : (i += 1) self.chain(&acc, try self.compile(sub));
        if (max == inf) {
            const sp = try self.nfa.add(self.alloc, .{ .kind = .split });
            const f = try self.compile(sub);
            self.patch(f.holes.items, sp);
            if (greedy) self.nfa.states.items[sp].out = f.start else self.nfa.states.items[sp].out1 = f.start;
            var h: Holes = .empty;
            try h.append(self.tmp, .{ .state = sp, .which = if (greedy) 1 else 0 });
            self.chain(&acc, .{ .start = sp, .holes = h });
        } else if (max > min) {
            var exits: Holes = .empty;
            var chain_start: u32 = 0;
            var prev: ?Holes = null;
            var j: u32 = min;
            while (j < max) : (j += 1) {
                const sp = try self.nfa.add(self.alloc, .{ .kind = .split });
                const f = try self.compile(sub);
                if (greedy) self.nfa.states.items[sp].out = f.start else self.nfa.states.items[sp].out1 = f.start;
                try exits.append(self.tmp, .{ .state = sp, .which = if (greedy) 1 else 0 });
                if (prev) |ph| self.patch(ph.items, sp) else chain_start = sp;
                prev = f.holes;
            }
            try exits.appendSlice(self.tmp, prev.?.items);
            self.chain(&acc, .{ .start = chain_start, .holes = exits });
        }
        if (acc) |a| return a;
        return self.single(.{ .kind = .jump });
    }
};

pub const Match = struct { start: usize, end: usize };

pub const Regex = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    opts: Options,
    nfa: Nfa,
    ngroups: u32,
    has_word_assert: bool,
    has_assert: bool,
    sensitive: bool,
    classmap: [256]u8,
    nclasses: usize,
    class_rep: [256]u8,
    word_class: [256]bool,
    nl_class: u8,
    first_bytes: ByteSet,
    can_be_empty: bool,
    must: ?[]const u8,
    literal_only: ?[]const u8,
    fwd: Dfa,
    anc: Dfa,

    pub fn compile(alloc: Allocator, patterns: []const []const u8, opts: Options) CompileError!*Regex {
        const self = try alloc.create(Regex);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.arena = std.heap.ArenaAllocator.init(alloc);
        errdefer self.arena.deinit();
        self.opts = opts;
        const arena = self.arena.allocator();
        var alts: std.ArrayList(*Node) = .empty;
        var has_word = false;
        var has_assert = false;
        var sensitive = false;
        var ngroups: u32 = 0;
        for (patterns) |pat| {
            var p: Parser = .{ .arena = arena, .src = pat, .opts = opts, .ngroups = ngroups };
            const n = try p.parseAlt();
            if (p.pos != p.src.len) return error.Invalid;
            ngroups = p.ngroups;
            has_word = has_word or p.has_word_assert;
            has_assert = has_assert or p.has_assert;
            sensitive = sensitive or p.sensitive;
            try alts.append(arena, n);
        }
        var ast = if (alts.items.len == 1) alts.items[0] else blk: {
            const n = try arena.create(Node);
            n.* = .{ .alt = alts.items };
            break :blk n;
        };
        if (opts.whole_line) {
            const items = try arena.alloc(*Node, 3);
            items[0] = try arena.create(Node);
            items[0].* = .{ .assert = .bol };
            items[1] = ast;
            items[2] = try arena.create(Node);
            items[2].* = .{ .assert = .eol };
            ast = try arena.create(Node);
            ast.* = .{ .cat = items };
        }
        var nfa: Nfa = .{};
        errdefer nfa.deinit(alloc);
        var tmp_arena = std.heap.ArenaAllocator.init(alloc);
        defer tmp_arena.deinit();
        var comp: Compiler = .{ .alloc = alloc, .tmp = tmp_arena.allocator(), .nfa = &nfa };
        const frag = try comp.compile(ast);
        const m = try nfa.add(alloc, .{ .kind = .match });
        comp.patch(frag.holes.items, m);
        nfa.start = frag.start;
        nfa.ngroups = ngroups;
        self.nfa = nfa;
        self.ngroups = ngroups;
        self.has_word_assert = has_word;
        self.has_assert = has_assert;
        self.sensitive = sensitive;
        self.computeClasses();
        try self.computeFirst();
        self.must = null;
        self.literal_only = null;
        self.analyzeLiterals(ast);
        self.fwd = try Dfa.init(alloc, self, true);
        errdefer self.fwd.deinit();
        self.anc = try Dfa.init(alloc, self, false);
        return self;
    }

    pub fn deinit(self: *Regex) void {
        const alloc = self.alloc;
        self.fwd.deinit();
        self.anc.deinit();
        self.nfa.deinit(alloc);
        self.arena.deinit();
        alloc.destroy(self);
    }

    fn computeClasses(self: *Regex) void {
        var cls = [_]u16{0} ** 256;
        var ncls: u16 = 1;
        const Refine = struct {
            fn run(cls_: *[256]u16, n: *u16, set: ByteSet) void {
                var map = [_]i32{-1} ** 512;
                var next: u16 = 0;
                var new_cls: [256]u16 = undefined;
                for (0..256) |b| {
                    const key: usize = @as(usize, cls_[b]) * 2 + @intFromBool(set.has(@intCast(b)));
                    if (map[key] < 0) {
                        map[key] = next;
                        next += 1;
                    }
                    new_cls[b] = @intCast(map[key]);
                }
                cls_.* = new_cls;
                n.* = next;
            }
        };
        for (self.nfa.sets.items) |s| Refine.run(&cls, &ncls, s);
        if (self.has_word_assert) {
            var wordset: ByteSet = .{};
            for (0..256) |b| if (isWordByte(@intCast(b))) wordset.add(@intCast(b));
            Refine.run(&cls, &ncls, wordset);
        }
        var nl: ByteSet = .{};
        nl.add('\n');
        Refine.run(&cls, &ncls, nl);
        self.nclasses = ncls;
        for (0..256) |b| self.classmap[b] = @intCast(cls[b]);
        var seen = [_]bool{false} ** 256;
        for (0..256) |b| {
            const c = self.classmap[b];
            if (!seen[c]) {
                seen[c] = true;
                self.class_rep[c] = @intCast(b);
            }
        }
        for (0..ncls) |c| self.word_class[c] = isWordByte(self.class_rep[c]);
        self.nl_class = self.classmap['\n'];
    }

    fn computeFirst(self: *Regex) CompileError!void {
        var fb: ByteSet = .{};
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(self.alloc, self.nfa.states.items.len);
        defer seen.deinit(self.alloc);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.alloc);
        try stack.append(self.alloc, self.nfa.start);
        var empty_ok = false;
        while (stack.pop()) |s| {
            if (seen.isSet(s)) continue;
            seen.set(s);
            const st = self.nfa.states.items[s];
            switch (st.kind) {
                .byteset => fb.unite(self.nfa.sets.items[st.arg]),
                .split => {
                    try stack.append(self.alloc, st.out);
                    try stack.append(self.alloc, st.out1);
                },
                .jump, .save, .assert => try stack.append(self.alloc, st.out),
                .match => empty_ok = true,
            }
        }
        self.first_bytes = fb;
        self.can_be_empty = empty_ok;
    }

    fn analyzeLiterals(self: *Regex, ast: *const Node) void {
        const arena = self.arena.allocator();
        if (self.opts.icase) return;
        var lit: std.ArrayList(u8) = .empty;
        if (pureLiteral(ast, &lit, arena)) {
            if (lit.items.len > 0) self.literal_only = lit.items;
            return;
        }
        var best: []const u8 = "";
        var cur: std.ArrayList(u8) = .empty;
        findMust(ast, &cur, &best, arena);
        flushMust(&cur, &best);
        if (best.len >= 2) self.must = best;
    }

    fn pureLiteral(n: *const Node, out: *std.ArrayList(u8), arena: Allocator) bool {
        switch (n.*) {
            .set => |s| {
                const b = s.single() orelse return false;
                out.append(arena, b) catch return false;
                return true;
            },
            .cat => |items| {
                for (items) |it| if (!pureLiteral(it, out, arena)) return false;
                return true;
            },
            else => return false,
        }
    }

    fn flushMust(cur: *std.ArrayList(u8), best: *[]const u8) void {
        if (cur.items.len > best.len) best.* = cur.items;
        cur.* = .empty;
    }

    fn findMust(n: *const Node, cur: *std.ArrayList(u8), best: *[]const u8, arena: Allocator) void {
        switch (n.*) {
            .set => |s| {
                if (s.single()) |b| {
                    cur.append(arena, b) catch {};
                } else flushMust(cur, best);
            },
            .cat => |items| for (items) |it| findMust(it, cur, best, arena),
            .group => |g| findMust(g.sub, cur, best, arena),
            .assert => {},
            .repeat => |r| {
                flushMust(cur, best);
                if (r.min >= 1) {
                    findMust(r.sub, cur, best, arena);
                    flushMust(cur, best);
                }
            },
            else => flushMust(cur, best),
        }
    }

    pub fn isMatch(self: *Regex, hay: []const u8) bool {
        if (self.literal_only) |l| return common.findBytes(hay, l, 0) != null;
        if (self.must) |m| if (common.findBytes(hay, m, 0) == null) return false;
        return self.fwd.search(hay, 0) != null;
    }

    pub fn searchBuffer(self: *Regex, buf: []const u8, from: usize) ?usize {
        if (self.literal_only) |l| return common.findBytes(buf, l, from);
        if (self.must) |m| {
            var pos = from;
            while (true) {
                const q = common.findBytes(buf, m, pos) orelse return null;
                const ls = if (common.findLastByte(buf[pos..q], '\n')) |i| pos + i + 1 else pos;
                const le = std.mem.findScalarPos(u8, buf, q, '\n') orelse buf.len;
                if (self.fwd.search(buf[ls..le], 0)) |p| return ls + p;
                if (le >= buf.len) return null;
                pos = le + 1;
            }
        }
        return self.fwd.search(buf, from);
    }

    pub fn longestAt(self: *Regex, hay: []const u8, at: usize, ends: ?*std.ArrayList(usize)) ?usize {
        return self.anc.longest(hay, at, ends);
    }

    pub fn find(self: *Regex, hay: []const u8, from: usize) ?Match {
        var s = from;
        while (s <= hay.len) : (s += 1) {
            if (!self.can_be_empty) {
                while (s < hay.len and !self.first_bytes.has(hay[s])) s += 1;
                if (s >= hay.len) return null;
            }
            if (self.anc.longest(hay, s, null)) |e| return .{ .start = s, .end = e };
        }
        return null;
    }
};

const flag_unknown: u32 = 1;
const flag_match: u32 = 2;
const flag_dead: u32 = 3;

const Dfa = struct {
    alloc: Allocator,
    re: *Regex,
    unanchored: bool,
    stride: u32,
    trans: std.ArrayList(u32) = .empty,
    keys: std.ArrayList([]u32) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    eof: std.ArrayList(u8) = .empty,
    starts: [4]u32 = .{ 0, 0, 0, 0 },
    start_set: [4]bool = .{ false, false, false, false },
    mark: []u32,
    mark_gen: u32 = 0,
    stack: std.ArrayList(u32) = .empty,
    tmp: std.ArrayList(u32) = .empty,
    resolved: std.ArrayList(u32) = .empty,

    const max_states = 3000;

    const Ctx = struct { at_start: bool, prev_word: bool, next_eol: bool, next_word: bool };

    fn init(alloc: Allocator, re: *Regex, unanchored: bool) !Dfa {
        var d: Dfa = .{
            .alloc = alloc,
            .re = re,
            .unanchored = unanchored,
            .stride = @intCast(re.nclasses),
            .mark = try alloc.alloc(u32, re.nfa.states.items.len),
        };
        errdefer alloc.free(d.mark);
        @memset(d.mark, 0);
        try d.reset();
        return d;
    }

    fn deinit(self: *Dfa) void {
        for (self.keys.items) |k| self.alloc.free(k);
        self.keys.deinit(self.alloc);
        self.trans.deinit(self.alloc);
        self.map.deinit(self.alloc);
        self.eof.deinit(self.alloc);
        self.stack.deinit(self.alloc);
        self.tmp.deinit(self.alloc);
        self.resolved.deinit(self.alloc);
        self.alloc.free(self.mark);
    }

    fn reset(self: *Dfa) !void {
        for (self.keys.items) |k| self.alloc.free(k);
        self.keys.clearRetainingCapacity();
        self.trans.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.eof.clearRetainingCapacity();
        self.start_set = .{ false, false, false, false };
        _ = try self.addState(&.{}, 0);
        for (self.trans.items[0..self.stride]) |*t| t.* = flag_dead;
        self.eof.items[0] = 1;
    }

    fn addState(self: *Dfa, ids: []const u32, flags: u32) !u32 {
        const key = try self.alloc.alloc(u32, ids.len + 1);
        errdefer self.alloc.free(key);
        key[0] = flags;
        @memcpy(key[1..], ids);
        if (self.map.get(std.mem.sliceAsBytes(key))) |id| {
            self.alloc.free(key);
            return id;
        }
        const id: u32 = @intCast(self.keys.items.len);
        try self.keys.append(self.alloc, key);
        errdefer _ = self.keys.pop();
        try self.map.put(self.alloc, std.mem.sliceAsBytes(self.keys.items[id]), id);
        try self.trans.appendNTimes(self.alloc, flag_unknown, self.stride);
        try self.eof.append(self.alloc, 0);
        return id;
    }

    fn offset(self: *const Dfa, id: u32) u32 {
        return id * self.stride;
    }

    fn sidOf(self: *const Dfa, off: u32) u32 {
        return off / self.stride;
    }

    fn nextGen(self: *Dfa) void {
        self.mark_gen +%= 1;
        if (self.mark_gen == 0) {
            @memset(self.mark, 0);
            self.mark_gen = 1;
        }
    }

    fn addClosure(self: *Dfa, s0: u32, out: *std.ArrayList(u32)) !void {
        try self.stack.append(self.alloc, s0);
        const nfa = &self.re.nfa;
        while (self.stack.pop()) |s| {
            if (self.mark[s] == self.mark_gen) continue;
            self.mark[s] = self.mark_gen;
            const st = nfa.states.items[s];
            switch (st.kind) {
                .jump, .save => try self.stack.append(self.alloc, st.out),
                .split => {
                    try self.stack.append(self.alloc, st.out1);
                    try self.stack.append(self.alloc, st.out);
                },
                .assert, .byteset, .match => try out.append(self.alloc, s),
            }
        }
    }

    fn assertHolds(a: Assert, c: Ctx) bool {
        return switch (a) {
            .bol => c.at_start,
            .eol => c.next_eol,
            .word_b => c.prev_word != c.next_word,
            .nword_b => c.prev_word == c.next_word,
            .word_start => !c.prev_word and c.next_word,
            .word_end => c.prev_word and !c.next_word,
        };
    }

    fn resolve(self: *Dfa, key: []const u32, ctx: Ctx) !void {
        const nfa = &self.re.nfa;
        self.resolved.clearRetainingCapacity();
        self.nextGen();
        for (key[1..]) |s0| {
            try self.stack.append(self.alloc, s0);
            while (self.stack.pop()) |s| {
                if (self.mark[s] == self.mark_gen) continue;
                self.mark[s] = self.mark_gen;
                const st = nfa.states.items[s];
                switch (st.kind) {
                    .jump, .save => try self.stack.append(self.alloc, st.out),
                    .split => {
                        try self.stack.append(self.alloc, st.out1);
                        try self.stack.append(self.alloc, st.out);
                    },
                    .assert => if (assertHolds(@enumFromInt(st.arg), ctx)) try self.stack.append(self.alloc, st.out),
                    .byteset, .match => try self.resolved.append(self.alloc, s),
                }
            }
        }
    }

    fn startState(self: *Dfa, flags: u32) !u32 {
        if (self.start_set[flags]) return self.starts[flags];
        self.nextGen();
        self.tmp.clearRetainingCapacity();
        try self.addClosure(self.re.nfa.start, &self.tmp);
        std.mem.sort(u32, self.tmp.items, {}, std.sort.asc(u32));
        const id = try self.addState(self.tmp.items, flags);
        self.starts[flags] = id;
        self.start_set[flags] = true;
        return id;
    }

    fn computeEof(self: *Dfa, s: u32) !bool {
        const key = self.keys.items[s];
        const flags = key[0];
        try self.resolve(key, .{ .at_start = flags & 2 != 0, .prev_word = flags & 1 != 0, .next_eol = true, .next_word = false });
        var matched = false;
        for (self.resolved.items) |n| {
            if (self.re.nfa.states.items[n].kind == .match) {
                matched = true;
                break;
            }
        }
        self.eof.items[s] = if (matched) 2 else 1;
        return matched;
    }

    fn compute(self: *Dfa, s: u32, col: usize) !u32 {
        const re = self.re;
        const key = self.keys.items[s];
        const flags = key[0];
        const is_nl = col == re.nl_class and re.opts.line_mode;
        try self.resolve(key, .{
            .at_start = flags & 2 != 0,
            .prev_word = flags & 1 != 0,
            .next_eol = is_nl,
            .next_word = re.word_class[col],
        });
        var matched = false;
        const rep = re.class_rep[col];
        const resolved = try self.alloc.dupe(u32, self.resolved.items);
        defer self.alloc.free(resolved);
        self.tmp.clearRetainingCapacity();
        self.nextGen();
        var next_flags: u32 = 0;
        if (is_nl) {
            next_flags = 2;
            for (resolved) |n| if (re.nfa.states.items[n].kind == .match) {
                matched = true;
            };
        } else {
            if (re.word_class[col]) next_flags = 1;
            for (resolved) |n| {
                const st = re.nfa.states.items[n];
                switch (st.kind) {
                    .match => matched = true,
                    .byteset => if (re.nfa.sets.items[st.arg].has(rep)) try self.addClosure(st.out, &self.tmp),
                    else => {},
                }
            }
        }
        if (self.unanchored) try self.addClosure(re.nfa.start, &self.tmp);
        std.mem.sort(u32, self.tmp.items, {}, std.sort.asc(u32));
        if (self.keys.items.len >= max_states) {
            const saved = try self.alloc.dupe(u32, self.tmp.items);
            defer self.alloc.free(saved);
            try self.reset();
            const nid = try self.addState(saved, next_flags);
            return (self.offset(nid) << 2) | (if (matched) flag_match else 0);
        }
        const nid: u32 = if (self.tmp.items.len == 0) 0 else try self.addState(self.tmp.items, next_flags);
        var v: u32 = self.offset(nid) << 2;
        if (matched) v |= flag_match else if (nid == 0) v |= flag_dead;
        self.trans.items[self.offset(s) + col] = v;
        return v;
    }

    fn flagsAt(hay: []const u8, at: usize, line_mode: bool) u32 {
        if (at == 0) return 2;
        const p = hay[at - 1];
        if (line_mode and p == '\n') return 2;
        return if (isWordByte(p)) 1 else 0;
    }

    fn search(self: *Dfa, hay: []const u8, from: usize) ?usize {
        const re = self.re;
        const sid = self.startState(flagsAt(hay, from, re.opts.line_mode)) catch return null;
        var off = self.offset(sid);
        var i = from;
        const cm = &re.classmap;
        const n = hay.len;
        while (i < n) {
            const t = self.trans.items.ptr;
            while (i < n) {
                const v = t[off + cm[hay[i]]];
                if (v & 3 != 0) break;
                off = v >> 2;
                i += 1;
            }
            if (i >= n) break;
            var v = self.trans.items[off + cm[hay[i]]];
            if (v == flag_unknown) v = self.compute(self.sidOf(off), cm[hay[i]]) catch return null;
            switch (v & 3) {
                flag_match => return i,
                flag_dead => return null,
                else => {
                    off = v >> 2;
                    i += 1;
                },
            }
        }
        const fin = self.sidOf(off);
        var e = self.eof.items[fin];
        if (e == 0) e = if (self.computeEof(fin) catch return null) 2 else 1;
        return if (e == 2) n else null;
    }

    fn longest(self: *Dfa, hay: []const u8, at: usize, ends: ?*std.ArrayList(usize)) ?usize {
        const re = self.re;
        const sid0 = self.startState(flagsAt(hay, at, re.opts.line_mode)) catch return null;
        var off = self.offset(sid0);
        var i = at;
        var best: ?usize = null;
        const cm = &re.classmap;
        while (i < hay.len) {
            var v = self.trans.items[off + cm[hay[i]]];
            if (v == flag_unknown) v = self.compute(self.sidOf(off), cm[hay[i]]) catch return best;
            if (v & 3 == flag_match) {
                best = i;
                if (ends) |e| e.append(self.alloc, i) catch {};
            }
            off = v >> 2;
            if (off == 0) return best;
            i += 1;
        }
        const fin = self.sidOf(off);
        var e = self.eof.items[fin];
        if (e == 0) e = if (self.computeEof(fin) catch return best) 2 else 1;
        if (e == 2) {
            best = hay.len;
            if (ends) |el| el.append(self.alloc, hay.len) catch {};
        }
        return best;
    }
};

fn expectMatch(syntax: Syntax, pat: []const u8, hay: []const u8, want: ?[2]usize) !void {
    const re = try Regex.compile(std.testing.allocator, &.{pat}, .{ .syntax = syntax });
    defer re.deinit();
    const m = re.find(hay, 0);
    if (want) |w| {
        try std.testing.expect(m != null);
        try std.testing.expectEqual(w[0], m.?.start);
        try std.testing.expectEqual(w[1], m.?.end);
    } else try std.testing.expect(m == null);
    try std.testing.expectEqual(want != null, re.isMatch(hay));
}

test "ere basics" {
    try expectMatch(.ere, "abc", "xxabcxx", .{ 2, 5 });
    try expectMatch(.ere, "a.c", "xxabcxx", .{ 2, 5 });
    try expectMatch(.ere, "ab|abcd", "xabcd", .{ 1, 5 });
    try expectMatch(.ere, "a+", "baaac", .{ 1, 4 });
    try expectMatch(.ere, "^abc", "abcabc", .{ 0, 3 });
    try expectMatch(.ere, "abc$", "abcabc", .{ 3, 6 });
    try expectMatch(.ere, "^abc$", "abcabc", null);
    try expectMatch(.ere, "[0-9]+", "ab123cd", .{ 2, 5 });
    try expectMatch(.ere, "[^a-c]+", "abxyzc", .{ 2, 5 });
    try expectMatch(.ere, "(ab)+c", "xababc", .{ 1, 6 });
    try expectMatch(.ere, "a{2,3}", "aaaa", .{ 0, 3 });
    try expectMatch(.ere, "\\bfoo\\b", "a foo b", .{ 2, 5 });
    try expectMatch(.ere, "\\bfoo\\b", "afoo b", null);
    try expectMatch(.ere, "\\<foo", "a foo", .{ 2, 5 });
    try expectMatch(.ere, "foo\\>", "a foo", .{ 2, 5 });
    try expectMatch(.ere, "x*", "abc", .{ 0, 0 });
    try expectMatch(.ere, "[[:digit:]]+", "ab42", .{ 2, 4 });
}

test "bre basics" {
    try expectMatch(.bre, "a*b", "xaab", .{ 1, 4 });
    try expectMatch(.bre, "a\\+b", "xaab", .{ 1, 4 });
    try expectMatch(.bre, "a\\|b", "xb", .{ 1, 2 });
    try expectMatch(.bre, "\\(ab\\)*c", "ababc", .{ 0, 5 });
    try expectMatch(.bre, "a\\{2\\}", "aaa", .{ 0, 2 });
    try expectMatch(.bre, "*a", "x*a", .{ 1, 3 });
    try expectMatch(.bre, "a+b", "a+b", .{ 0, 3 });
    try expectMatch(.bre, "^*a", "*a", .{ 0, 2 });
    try expectMatch(.bre, "a^b", "a^b", .{ 0, 3 });
    try expectMatch(.bre, "a$b", "a$b", .{ 0, 3 });
}

test "case insensitive and literals" {
    const re = try Regex.compile(std.testing.allocator, &.{"hello"}, .{ .syntax = .bre, .icase = true });
    defer re.deinit();
    try std.testing.expect(re.isMatch("say HeLLo"));
    try std.testing.expect(!re.isMatch("say help"));
    const re2 = try Regex.compile(std.testing.allocator, &.{"foo.*bar"}, .{ .syntax = .bre });
    defer re2.deinit();
    try std.testing.expect(re2.must != null);
    try std.testing.expect(re2.isMatch("xx foo yy bar"));
    try std.testing.expect(!re2.isMatch("xx bar yy foo"));
}

test "unsupported and invalid" {
    try std.testing.expectError(error.Unsupported, Regex.compile(std.testing.allocator, &.{"(a)\\1"}, .{ .syntax = .ere }));
    try std.testing.expectError(error.Unsupported, Regex.compile(std.testing.allocator, &.{"*a"}, .{ .syntax = .ere }));
    try std.testing.expectError(error.Invalid, Regex.compile(std.testing.allocator, &.{"[a"}, .{ .syntax = .ere }));
    try std.testing.expectError(error.Invalid, Regex.compile(std.testing.allocator, &.{"a)"}, .{ .syntax = .ere }));
}

test "buffer search spans lines" {
    const re = try Regex.compile(std.testing.allocator, &.{"b+c"}, .{ .syntax = .ere });
    defer re.deinit();
    const buf = "aaa\nxbbc\nzzz\n";
    const p = re.searchBuffer(buf, 0).?;
    try std.testing.expectEqual(@as(usize, 8), p);
    try std.testing.expect(re.searchBuffer(buf, 9) == null);
    const re2 = try Regex.compile(std.testing.allocator, &.{"^zzz$"}, .{ .syntax = .ere });
    defer re2.deinit();
    try std.testing.expect(re2.searchBuffer(buf, 0) != null);
    const re3 = try Regex.compile(std.testing.allocator, &.{"a$"}, .{ .syntax = .ere });
    defer re3.deinit();
    try std.testing.expectEqual(@as(?usize, 3), re3.searchBuffer(buf, 0));
}

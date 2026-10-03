const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const regex = @import("regex.zig");
const uni = @import("uni.zig");
const ucp = @import("ucp.zig");
const unicode_sets = @import("unicode_sets.zig");
const Ctx = common.Ctx;
const Stdio = common.Stdio;

const win_size: usize = 98304;

const specs = [_]common.OptSpec{
    .{ .id = 'E', .short = 'E', .long = "extended-regexp" },
    .{ .id = 'F', .short = 'F', .long = "fixed-strings" },
    .{ .id = 'G', .short = 'G', .long = "basic-regexp" },
    .{ .id = 'e', .short = 'e', .long = "regexp", .arg = .required },
    .{ .id = 'f', .short = 'f', .long = "file", .arg = .required },
    .{ .id = 'i', .short = 'i', .long = "ignore-case" },
    .{ .id = 'i', .short = 'y' },
    .{ .id = 'N', .long = "no-ignore-case" },
    .{ .id = 'v', .short = 'v', .long = "invert-match" },
    .{ .id = 'w', .short = 'w', .long = "word-regexp" },
    .{ .id = 'x', .short = 'x', .long = "line-regexp" },
    .{ .id = 'c', .short = 'c', .long = "count" },
    .{ .id = 'l', .short = 'l', .long = "files-with-matches" },
    .{ .id = 'L', .short = 'L', .long = "files-without-match" },
    .{ .id = 'm', .short = 'm', .long = "max-count", .arg = .required },
    .{ .id = 'o', .short = 'o', .long = "only-matching" },
    .{ .id = 'q', .short = 'q', .long = "quiet" },
    .{ .id = 'q', .long = "silent" },
    .{ .id = 's', .short = 's', .long = "no-messages" },
    .{ .id = 'b', .short = 'b', .long = "byte-offset" },
    .{ .id = 'H', .short = 'H', .long = "with-filename" },
    .{ .id = 'h', .short = 'h', .long = "no-filename" },
    .{ .id = 'n', .short = 'n', .long = "line-number" },
    .{ .id = 'Z', .short = 'Z', .long = "null" },
    .{ .id = 'A', .short = 'A', .long = "after-context", .arg = .required },
    .{ .id = 'B', .short = 'B', .long = "before-context", .arg = .required },
    .{ .id = 'C', .short = 'C', .long = "context", .arg = .required },
    .{ .id = 'a', .short = 'a', .long = "text" },
    .{ .id = 'I', .short = 'I' },
    .{ .id = 'r', .short = 'r', .long = "recursive" },
    .{ .id = 'R', .short = 'R', .long = "dereference-recursive" },
    .{ .id = 'U', .short = 'U', .long = "binary" },
    .{ .id = 'd', .short = 'd', .long = "directories", .arg = .required },
    .{ .id = 1000, .long = "label", .arg = .required },
    .{ .id = 1001, .long = "binary-files", .arg = .required },
    .{ .id = 1002, .long = "include", .arg = .required },
    .{ .id = 1003, .long = "exclude", .arg = .required },
    .{ .id = 1004, .long = "exclude-dir", .arg = .required },
    .{ .id = 1005, .long = "group-separator", .arg = .required },
    .{ .id = 1006, .long = "no-group-separator" },
    .{ .id = 1007, .long = "line-buffered" },
    .{ .id = 1008, .long = "color", .arg = .optional },
    .{ .id = 1008, .long = "colour", .arg = .optional },
};

const Syntax = enum { bre, ere, fixed };
const Binary = enum { binary, text, without_match };
const Dirs = enum { read, skip, recurse };

const Config = struct {
    syntax: Syntax = .bre,
    icase: bool = false,
    invert: bool = false,
    word: bool = false,
    line: bool = false,
    count: bool = false,
    list_match: bool = false,
    list_nomatch: bool = false,
    quiet: bool = false,
    no_messages: bool = false,
    only: bool = false,
    byte_offset: bool = false,
    with_filename: ?bool = null,
    no_filename: bool = false,
    line_number: bool = false,
    null_name: bool = false,
    after: i64 = -1,
    before: i64 = -1,
    max_count: ?u64 = null,
    binary: Binary = .binary,
    dirs: Dirs = .read,
    recursive: bool = false,
    deref: bool = false,
    label: []const u8 = "(standard input)",
    group_sep: ?[]const u8 = "--",
    pattern_from_file: bool = false,
    has_include: bool = false,
    has_exclude: bool = false,
    has_exclude_dir: bool = false,
    ignore_binary_I: bool = false,
};

const Parsed = struct {
    cfg: Config = .{},
    patterns: std.ArrayList([]const u8) = .empty,
    pattern_files: std.ArrayList([]const u8) = .empty,
    operands: std.ArrayList([]const u8) = .empty,
    includes: std.ArrayList([]const u8) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    exclude_dirs: std.ArrayList([]const u8) = .empty,
    explicit_pattern: bool = false,
    ok: bool = true,

    fn deinit(self: *Parsed, a: std.mem.Allocator) void {
        self.patterns.deinit(a);
        self.pattern_files.deinit(a);
        self.operands.deinit(a);
        self.includes.deinit(a);
        self.excludes.deinit(a);
        self.exclude_dirs.deinit(a);
    }
};

fn parseNum(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    return common.parseUint(s);
}

fn parseArgs(a: std.mem.Allocator, argv: []const []const u8, err: ?*Io.Writer, strict: bool) !Parsed {
    var pr: Parsed = .{};
    errdefer pr.deinit(a);
    var p = common.Parser.init(argv, &specs, err);
    p.digits_id = 2000;
    var ctx_digits: ?[]const u8 = null;
    while (true) {
        const it = (p.next() catch {
            pr.ok = false;
            return pr;
        }) orelse break;
        switch (it) {
            .operand => |o| try pr.operands.append(a, o),
            .opt => |m| switch (m.id) {
                'E' => pr.cfg.syntax = .ere,
                'F' => pr.cfg.syntax = .fixed,
                'G' => pr.cfg.syntax = .bre,
                'e' => {
                    try pr.patterns.append(a, m.arg.?);
                    pr.explicit_pattern = true;
                },
                'f' => {
                    try pr.pattern_files.append(a, m.arg.?);
                    pr.explicit_pattern = true;
                },
                'i' => pr.cfg.icase = true,
                'N' => pr.cfg.icase = false,
                'v' => pr.cfg.invert = true,
                'w' => pr.cfg.word = true,
                'x' => pr.cfg.line = true,
                'c' => pr.cfg.count = true,
                'l' => {
                    pr.cfg.list_match = true;
                    pr.cfg.list_nomatch = false;
                },
                'L' => {
                    pr.cfg.list_nomatch = true;
                    pr.cfg.list_match = false;
                },
                'm' => {
                    pr.cfg.max_count = parseNum(m.arg.?) orelse {
                        pr.ok = false;
                        return pr;
                    };
                },
                'o' => pr.cfg.only = true,
                'q' => pr.cfg.quiet = true,
                's' => pr.cfg.no_messages = true,
                'b' => pr.cfg.byte_offset = true,
                'H' => {
                    pr.cfg.with_filename = true;
                },
                'h' => pr.cfg.with_filename = false,
                'n' => pr.cfg.line_number = true,
                'Z' => pr.cfg.null_name = true,
                'A', 'B', 'C' => {
                    const n = parseNum(m.arg.?) orelse {
                        pr.ok = false;
                        return pr;
                    };
                    if (n > 1 << 40) {
                        pr.ok = false;
                        return pr;
                    }
                    const v: i64 = @intCast(n);
                    switch (m.id) {
                        'A' => pr.cfg.after = v,
                        'B' => pr.cfg.before = v,
                        else => {
                            pr.cfg.after = v;
                            pr.cfg.before = v;
                        },
                    }
                },
                2000 => ctx_digits = m.arg,
                'a' => pr.cfg.binary = .text,
                'I' => pr.cfg.binary = .without_match,
                'r' => {
                    pr.cfg.recursive = true;
                    pr.cfg.dirs = .recurse;
                },
                'R' => {
                    pr.cfg.recursive = true;
                    pr.cfg.deref = true;
                    pr.cfg.dirs = .recurse;
                },
                'U' => {},
                'd' => {
                    const v = m.arg.?;
                    if (std.mem.eql(u8, v, "read")) {
                        pr.cfg.dirs = .read;
                    } else if (std.mem.eql(u8, v, "skip")) {
                        pr.cfg.dirs = .skip;
                    } else if (std.mem.eql(u8, v, "recurse")) {
                        pr.cfg.dirs = .recurse;
                        pr.cfg.recursive = true;
                    } else pr.ok = false;
                },
                1000 => pr.cfg.label = m.arg.?,
                1001 => {
                    const v = m.arg.?;
                    if (std.mem.eql(u8, v, "binary")) {
                        pr.cfg.binary = .binary;
                    } else if (std.mem.eql(u8, v, "text")) {
                        pr.cfg.binary = .text;
                    } else if (std.mem.eql(u8, v, "without-match")) {
                        pr.cfg.binary = .without_match;
                    } else pr.ok = false;
                },
                1002 => try pr.includes.append(a, m.arg.?),
                1003 => try pr.excludes.append(a, m.arg.?),
                1004 => try pr.exclude_dirs.append(a, m.arg.?),
                1005 => pr.cfg.group_sep = m.arg.?,
                1006 => pr.cfg.group_sep = null,
                1007 => {},
                1008 => {
                    const v = m.arg orelse "auto";
                    if (!(std.mem.eql(u8, v, "never") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "none"))) pr.ok = false;
                },
                else => unreachable,
            },
        }
    }
    if (ctx_digits) |d| {
        const n = parseNum(d) orelse {
            pr.ok = false;
            return pr;
        };
        if (pr.cfg.after < 0 and pr.cfg.before < 0) {
            pr.cfg.after = @intCast(@min(n, 1 << 40));
            pr.cfg.before = pr.cfg.after;
        }
    }
    _ = strict;
    return pr;
}

fn regexOptions(cfg: Config, utf8: bool) regex.Options {
    return .{
        .syntax = switch (cfg.syntax) {
            .bre => .bre,
            .ere => .ere,
            .fixed => .fixed,
        },
        .icase = cfg.icase,
        .unicode = if (utf8) .glibc else .none,
        .line_mode = true,
        .whole_line = cfg.line,
    };
}

fn checkSupported(argv: []const []const u8, env: ?*const common.EnvView) bool {
    var buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var pr = parseArgs(a, argv, null, true) catch return false;
    if (!pr.ok) return false;
    const cfg = pr.cfg;
    if (pr.pattern_files.items.len > 0) {
        if (cfg.syntax != .fixed or cfg.icase) return false;
    }
    if (!pr.explicit_pattern) {
        if (pr.operands.items.len == 0) return false;
        pr.patterns.append(a, pr.operands.items[0]) catch return false;
    }
    if (cfg.only and (cfg.invert or cfg.after > 0 or cfg.before > 0 or cfg.after == 0 or cfg.before == 0)) return false;
    if (pr.includes.items.len > 0 and pr.excludes.items.len > 0) return false;
    if (cfg.count and cfg.only) return false;
    if (cfg.list_match and cfg.list_nomatch) return false;
    const utf8 = if (env) |e| common.isUtf8Locale(e) else false;
    if (env) |e| {
        if (common.ctypeKind(e) == .other) return false;
    }
    var pats: std.ArrayList([]const u8) = .empty;
    for (pr.patterns.items) |pat| {
        var it = std.mem.splitScalar(u8, pat, '\n');
        while (it.next()) |one| pats.append(a, one) catch return false;
    }
    if (pats.items.len == 0 and pr.pattern_files.items.len == 0) return false;
    if (pats.items.len > 0) {
        const re = regex.Regex.compile(std.heap.page_allocator, pats.items, regexOptions(cfg, utf8)) catch return false;
        defer re.deinit();
        if (cfg.word and re.can_be_empty) return false;
        if (utf8 and re.sensitive) return false;
        if (re.nfa.states.items.len > 20000) return false;
    }
    return true;
}

pub fn supports(argv: []const []const u8) bool {
    return checkSupported(argv, null);
}

pub fn supportsEnv(env: *const common.EnvView, argv: []const []const u8) bool {
    return checkSupported(argv, env);
}

const Block = struct { data: []u8, abs_off: u64, has_nul: bool, final: bool };

const page = 4096;

const BlockReader = struct {
    r: *Io.Reader,
    file: ?Io.File = null,
    io: Io = undefined,
    file_off: u64 = 0,
    alloc: std.mem.Allocator,
    raw: []align(page) u8 = &.{},
    pad: usize = 0,
    ds: usize = 0,
    de: usize = 0,
    abs_base: u64 = 0,
    pending_drop: usize = 0,
    eof: bool = false,
    read_err: bool = false,

    fn deinit(self: *BlockReader) void {
        if (self.raw.len > 0) self.alloc.free(self.raw);
    }

    fn grow(self: *BlockReader, need_pad: usize, need_tail: usize) !void {
        const new_pad = std.mem.alignForward(usize, @max(need_pad, 1), page);
        const dlen = self.de - self.ds;
        const new_len = @max(new_pad + need_tail, new_pad + win_size);
        const nb = try self.alloc.alignedAlloc(u8, .fromByteUnits(page), new_len);
        const nds = new_pad - @min(new_pad, self.pad - self.ds);
        _ = nds;
        const carry_before_pad = if (self.pad > self.ds) self.pad - self.ds else 0;
        const start = new_pad - carry_before_pad;
        @memcpy(nb[start .. start + dlen], self.raw[self.ds..self.de]);
        if (self.raw.len > 0) self.alloc.free(self.raw);
        self.raw = nb;
        self.pad = new_pad;
        self.ds = start;
        self.de = start + dlen;
    }

    fn next(self: *BlockReader) !?Block {
        if (self.raw.len == 0) try self.grow(0, win_size);
        if (self.pending_drop > 0) {
            const carry_len = (self.de - self.ds) - self.pending_drop;
            const src_start = self.ds + self.pending_drop;
            self.abs_base += self.pending_drop;
            self.pending_drop = 0;
            if (carry_len > self.pad) {
                self.ds = src_start;
                try self.grow(carry_len, win_size);
            } else {
                @memmove(self.raw[self.pad - carry_len .. self.pad], self.raw[src_start..self.de]);
                self.ds = self.pad - carry_len;
                self.de = self.pad;
            }
        }
        var has_nul = false;
        while (true) {
            if (self.eof and self.de == self.ds) return null;
            const loaded_end = self.abs_base + (self.de - self.ds);
            const target = (loaded_end / win_size + 1) * win_size;
            const scan_from = self.de;
            while (!self.eof and self.abs_base + (self.de - self.ds) < target) {
                const want: usize = @intCast(target - (self.abs_base + (self.de - self.ds)));
                if (self.de + want > self.raw.len) try self.grow(self.pad, (self.de - self.pad) + want);
                if (self.file) |f| {
                    const n = f.readPositional(self.io, &.{self.raw[self.de..][0..want]}, self.file_off) catch {
                        self.read_err = true;
                        self.eof = true;
                        break;
                    };
                    if (n == 0) {
                        self.eof = true;
                        break;
                    }
                    self.de += n;
                    self.file_off += n;
                } else {
                    if (self.r.bufferedLen() == 0) {
                        self.r.fillMore() catch |e| switch (e) {
                            error.EndOfStream => {
                                self.eof = true;
                                break;
                            },
                            error.ReadFailed => {
                                self.read_err = true;
                                self.eof = true;
                                break;
                            },
                        };
                    }
                    const b = self.r.buffered();
                    const take = @min(b.len, want);
                    @memcpy(self.raw[self.de..][0..take], b[0..take]);
                    self.de += take;
                    self.r.toss(take);
                }
            }
            if (std.mem.findScalar(u8, self.raw[scan_from..self.de], 0) != null) has_nul = true;
            const data = self.raw[self.ds..self.de];
            if (self.eof) {
                if (data.len == 0) return null;
                self.pending_drop = data.len;
                return .{ .data = data, .abs_off = self.abs_base, .has_nul = has_nul, .final = true };
            }
            if (common.findLastByte(data, '\n')) |i| {
                self.pending_drop = i + 1;
                return .{ .data = data[0 .. i + 1], .abs_off = self.abs_base, .has_nul = has_nul, .final = false };
            }
        }
    }
};

const Line = struct { ls: usize, le: usize, next: usize };

const Searcher = struct {
    ctx: *Ctx,
    io: Stdio,
    cfg: Config,
    re: ?*regex.Regex,
    utf8: bool,
    with_filename: bool,
    used: bool = false,
    out_quiet0: bool,
    done_on_match0: bool,
    ctx_enabled: bool,
    sep_name: u8 = ':',

    name: []const u8 = "",
    count: u64 = 0,
    out_quiet: bool = false,
    done_on_match: bool = false,
    binary_active: bool = false,
    nlines_first_null: u64 = 0,
    enc_error: bool = false,
    after_left: i64 = 0,
    last_out_line: u64 = 0,
    carry: std.ArrayList(u8) = .empty,
    carry_lines: u64 = 0,
    stop: bool = false,
    max_reached: bool = false,
    block_line0: u64 = 1,
    cache_valid: bool = false,
    cache_line: ?Line = null,
    group_open: bool = false,
    cursor_pos: usize = 0,
    cursor_line: u64 = 0,
    ends: std.ArrayList(usize) = .empty,
    zap: std.ArrayList(u8) = .empty,

    fn deinit(self: *Searcher) void {
        self.carry.deinit(self.ctx.alloc);
        self.ends.deinit(self.ctx.alloc);
        self.zap.deinit(self.ctx.alloc);
    }

    fn lineMatches(self: *Searcher, line: []const u8) bool {
        const re = self.re orelse return false;
        if (!self.cfg.word) return re.isMatch(line);
        if (!re.isMatch(line)) return false;
        return self.wordFind(line, 0) != null;
    }

    fn isWordAt(self: *const Searcher, line: []const u8, i: usize) bool {
        if (i >= line.len) return false;
        const c = line[i];
        if (c < 0x80 or !self.utf8) return std.ascii.isAlphanumeric(c) or c == '_';
        const n = std.unicode.utf8ByteSequenceLength(c) catch return false;
        if (i + n > line.len) return false;
        const cp = std.unicode.utf8Decode(line[i..][0..n]) catch return false;
        return ucp.inTable(&unicode_sets.glibc_word_ranges, cp);
    }

    fn isWordBefore(self: *const Searcher, line: []const u8, s: usize) bool {
        if (s == 0) return false;
        var k = s - 1;
        if (self.utf8) {
            var back: usize = 0;
            while (k > 0 and back < 3 and line[k] & 0xc0 == 0x80) : (back += 1) k -= 1;
        }
        return self.isWordAt(line, k);
    }

    fn wordFind(self: *Searcher, line: []const u8, from: usize) ?regex.Match {
        const re = self.re.?;
        var start = from;
        while (start <= line.len) {
            const m = re.find(line, start) orelse return null;
            const s = m.start;
            self.ends.clearRetainingCapacity();
            _ = re.longestAt(line, s, &self.ends);
            var len = m.end - s;
            while (true) {
                const e = s + len;
                if (!self.isWordBefore(line, s) and !self.isWordAt(line, e)) return .{ .start = s, .end = e };
                if (len == 0) break;
                len -= 1;
                if (len < from) break;
                const limit = s + len - from;
                var best: ?usize = null;
                for (self.ends.items) |en| {
                    if (en <= limit and en > s) best = en;
                }
                if (best) |bst| len = bst - s else break;
            }
            start = s + 1;
        }
        return null;
    }

    fn nextMatchLine(self: *Searcher, data: []const u8, pos: usize) ?Line {
        const re = self.re orelse return null;
        var p = pos;
        while (p < data.len) {
            const q = re.searchBuffer(data, p) orelse return null;
            if (q >= data.len) return null;
            const ls = if (common.findLastByte(data[p..q], '\n')) |i| p + i + 1 else p;
            const le = std.mem.findScalarPos(u8, data, q, '\n') orelse data.len;
            const next = if (le < data.len) le + 1 else data.len;
            if (!self.cfg.word or self.lineMatches(data[ls..le])) return .{ .ls = ls, .le = le, .next = next };
            p = next;
        }
        return null;
    }

    fn lineNoAt(self: *Searcher, data: []const u8, idx: usize) u64 {
        if (idx > self.cursor_pos) {
            self.cursor_line += common.countByte(data[self.cursor_pos..idx], '\n');
            self.cursor_pos = idx;
        }
        return self.cursor_line;
    }

    fn validUtf8(line: []const u8) bool {
        if (uni.isAscii(line)) return true;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] < 0x80) {
                i += 1;
                continue;
            }
            switch (uni.decode(line[i..])) {
                .ok => |d| i += d.len,
                else => return false,
            }
        }
        return true;
    }

    fn sepIfNeeded(self: *Searcher, lineno: u64) !void {
        if (self.ctx_enabled and self.used and (self.last_out_line == 0 or lineno != self.last_out_line + 1)) {
            if (self.cfg.group_sep) |gs| {
                try common.put(self.io.out, gs);
                try common.putByte(self.io.out, '\n');
            }
        }
    }

    fn prefix(self: *Searcher, lineno: u64, offset: u64, sep: u8) !void {
        const w = self.io.out;
        if (self.with_filename) {
            try common.put(w, self.name);
            if (self.cfg.null_name) try common.putByte(w, 0) else try common.putByte(w, sep);
        }
        if (self.cfg.line_number) {
            try common.putUint(w, lineno);
            try common.putByte(w, sep);
        }
        if (self.cfg.byte_offset) {
            try common.putUint(w, offset);
            try common.putByte(w, sep);
        }
    }

    fn emitLine(self: *Searcher, text: []const u8, lineno: u64, offset: u64, sep: u8) !bool {
        if (!self.group_open) {
            try self.sepIfNeeded(lineno);
            self.group_open = true;
            self.used = true;
        }
        if (self.utf8 and self.cfg.binary == .binary and !validUtf8(text)) {
            self.enc_error = true;
            return false;
        }
        try self.prefix(lineno, offset, sep);
        try common.put(self.io.out, text);
        try common.putByte(self.io.out, '\n');
        self.used = true;
        self.last_out_line = lineno;
        return true;
    }

    fn emitOnly(self: *Searcher, text: []const u8, lineno: u64, base_off: u64) !void {
        var start: usize = 0;
        while (start <= text.len) {
            const m = (if (self.cfg.word) self.wordFind(text, start) else self.re.?.find(text, start)) orelse break;
            if (m.end == m.start) {
                start = self.advance(text, m.end);
                continue;
            }
            const piece = text[m.start..m.end];
            if (self.utf8 and self.cfg.binary == .binary and !validUtf8(piece)) {
                self.enc_error = true;
                start = m.end;
                continue;
            }
            try self.prefix(lineno, base_off + m.start, ':');
            try common.put(self.io.out, piece);
            try common.putByte(self.io.out, '\n');
            self.used = true;
            self.last_out_line = lineno;
            start = m.end;
        }
    }

    fn advance(self: *Searcher, text: []const u8, i: usize) usize {
        var k = i + 1;
        if (self.utf8) {
            while (k < text.len and text[k] & 0xc0 == 0x80) k += 1;
        }
        return k;
    }

    fn contextPrint(self: *Searcher, data: []const u8, ls: usize, le: usize, lineno: u64, abs: u64) !void {
        _ = try self.emitLine(data[ls..le], lineno, abs + ls, '-');
    }

    fn lineEnd(data: []const u8, p: usize) usize {
        return std.mem.findScalarPos(u8, data, p, '\n') orelse data.len;
    }

    fn handleGap(self: *Searcher, data: []const u8, pos: usize, gap_end: usize, abs: u64, has_next: bool) !usize {
        if (!self.ctx_enabled) return gap_end;
        var p = pos;
        const quiet = self.out_quiet;
        if (self.after_left > 0 and p < gap_end) {
            const saved = self.group_open;
            self.group_open = true;
            while (self.after_left > 0 and p < gap_end) {
                const le = lineEnd(data, p);
                if (!quiet) try self.contextPrint(data, p, le, self.lineNoAt(data, p), abs);
                p = if (le < data.len) le + 1 else data.len;
                self.after_left -= 1;
            }
            self.group_open = saved;
        }
        if (quiet or self.cfg.before <= 0) {
            if (!has_next) {
                self.carry.clearRetainingCapacity();
                self.carry_lines = 0;
            }
            return gap_end;
        }
        if (!has_next) {
            try self.saveCarry(data, p, gap_end);
            return gap_end;
        }
        const b: u64 = @intCast(self.cfg.before);
        var start = gap_end;
        var got: u64 = 0;
        while (got < b and start > p) {
            const prev = if (start >= 2) common.findLastByte(data[p .. start - 1], '\n') else null;
            start = if (prev) |i| p + i + 1 else p;
            got += 1;
        }
        if (got < b and p == 0 and self.carry_lines > 0) {
            const take = @min(b - got, self.carry_lines);
            var cs: usize = self.carry.items.len;
            var c: u64 = 0;
            while (c < take) : (c += 1) {
                const prev = if (cs >= 2) common.findLastByte(self.carry.items[0 .. cs - 1], '\n') else null;
                cs = if (prev) |i| i + 1 else 0;
            }
            var q = cs;
            var ln = self.block_line0 - take;
            while (q < self.carry.items.len) {
                const e = std.mem.findScalarPos(u8, self.carry.items, q, '\n') orelse self.carry.items.len;
                _ = try self.emitLine(self.carry.items[q..e], ln, 0, '-');
                ln += 1;
                q = e + 1;
            }
        }
        var q = start;
        if (q < gap_end) {
            var ln = self.lineNoAt(data, q);
            while (q < gap_end) {
                const e = lineEnd(data, q);
                try self.contextPrint(data, q, e, ln, abs);
                ln += 1;
                q = e + 1;
            }
        }
        self.carry.clearRetainingCapacity();
        self.carry_lines = 0;
        return gap_end;
    }

    fn saveCarry(self: *Searcher, data: []const u8, p: usize, end: usize) !void {
        const b: u64 = @intCast(self.cfg.before);
        var start = end;
        var got: u64 = 0;
        while (got < b and start > p) {
            const prev = if (start >= 2) common.findLastByte(data[p .. start - 1], '\n') else null;
            start = if (prev) |i| p + i + 1 else p;
            got += 1;
        }
        if (got < b and p == 0 and self.carry_lines > 0 and end > 0) {
            try self.carry.appendSlice(self.ctx.alloc, data[start..end]);
            self.carry_lines += got;
            if (self.carry_lines > b) {
                var drop = self.carry_lines - b;
                var off: usize = 0;
                while (drop > 0) : (drop -= 1) off = std.mem.findScalarPos(u8, self.carry.items, off, '\n').? + 1;
                const rest = self.carry.items.len - off;
                @memmove(self.carry.items[0..rest], self.carry.items[off..]);
                self.carry.shrinkRetainingCapacity(rest);
                self.carry_lines = b;
            }
        } else {
            self.carry.clearRetainingCapacity();
            try self.carry.appendSlice(self.ctx.alloc, data[start..end]);
            self.carry_lines = got;
        }
    }

    fn cachedMatch(self: *Searcher, data: []const u8, p: usize) ?Line {
        if (self.cache_valid) {
            if (self.cache_line) |l| {
                if (l.ls >= p) return l;
            } else return null;
        }
        self.cache_line = self.nextMatchLine(data, p);
        self.cache_valid = true;
        return self.cache_line;
    }

    fn nextSelected(self: *Searcher, data: []const u8, pos: usize) ?Line {
        if (!self.cfg.invert) return self.nextMatchLine(data, pos);
        var p = pos;
        while (p < data.len) {
            if (self.cachedMatch(data, p)) |m| {
                if (m.ls == p) {
                    p = m.next;
                    continue;
                }
            }
            const le = lineEnd(data, p);
            return .{ .ls = p, .le = le, .next = if (le < data.len) le + 1 else data.len };
        }
        return null;
    }

    fn processBlock(self: *Searcher, blk_data: []const u8, abs: u64, final: bool, line0: u64) !void {
        var data = blk_data;
        var tmp: ?[]u8 = null;
        if (final and (data.len == 0 or data[data.len - 1] != '\n')) {
            try self.zap.ensureTotalCapacity(self.ctx.alloc, data.len + 1);
            self.zap.clearRetainingCapacity();
            self.zap.appendSliceAssumeCapacity(data);
            self.zap.appendAssumeCapacity('\n');
            tmp = self.zap.items;
            data = tmp.?;
        }
        if (self.binary_active and std.mem.findScalar(u8, data, 0) != null) {
            if (tmp == null) {
                try self.zap.ensureTotalCapacity(self.ctx.alloc, data.len);
                self.zap.clearRetainingCapacity();
                self.zap.appendSliceAssumeCapacity(data);
                tmp = self.zap.items;
            }
            for (tmp.?) |*c| if (c.* == 0) {
                c.* = '\n';
            };
            data = tmp.?;
        }
        if (self.out_quiet and !self.ctx_enabled and !self.cfg.word and !self.max_reached and (!self.cfg.invert or (!self.done_on_match and self.cfg.max_count == null))) {
            try self.processQuiet(data);
            return;
        }
        self.cursor_pos = 0;
        self.cursor_line = line0;
        self.block_line0 = line0;
        self.cache_valid = false;
        self.cache_line = null;
        var pos: usize = 0;
        var had_sel = false;
        if (self.max_reached) {
            try self.trailingBlock(data, pos, abs);
            return;
        }
        while (pos < data.len and !self.stop) {
            const sel = self.nextSelected(data, pos);
            const gap_end = if (sel) |s| s.ls else data.len;
            if (!(self.cfg.invert and gap_end == pos and had_sel)) self.group_open = false;
            pos = try self.handleGap(data, pos, gap_end, abs, sel != null);
            const s = sel orelse break;
            try self.onSelected(data, s, abs);
            had_sel = true;
            pos = s.next;
            if (self.max_reached and !self.stop) {
                try self.trailingBlock(data, pos, abs);
                return;
            }
        }
    }

    fn processQuiet(self: *Searcher, data: []const u8) !void {
        const re = self.re;
        var matched: u64 = 0;
        var pos: usize = 0;
        if (re) |r| {
            while (pos < data.len) {
                const q = r.searchBuffer(data, pos) orelse break;
                if (q >= data.len) break;
                const le = std.mem.findScalarPos(u8, data, q, '\n') orelse data.len;
                matched += 1;
                pos = if (le < data.len) le + 1 else data.len;
                if (!self.cfg.invert) {
                    if (self.done_on_match) break;
                    if (self.cfg.max_count) |m| if (self.count + matched >= m) break;
                }
            }
        }
        if (!self.cfg.invert) {
            self.count += matched;
            if (matched > 0 and (self.done_on_match or (self.cfg.max_count != null and self.count >= self.cfg.max_count.?))) self.stop = true;
            return;
        }
        var total = common.countByte(data, '\n');
        if (data.len > 0 and data[data.len - 1] != '\n') total += 1;
        self.count += total - matched;
    }

    fn onSelected(self: *Searcher, data: []const u8, s: Line, abs: u64) !void {
        const text = data[s.ls..s.le];
        self.count += 1;
        if (!self.out_quiet) {
            const lineno = self.lineNoAt(data, s.ls);
            if (self.cfg.only) {
                try self.emitOnly(text, lineno, abs + s.ls);
            } else if (!try self.emitLine(text, lineno, abs + s.ls, ':')) {
                self.after_left = 0;
                return;
            }
        }
        if (self.done_on_match) {
            self.stop = true;
            return;
        }
        if (self.cfg.max_count) |m| {
            if (self.count >= m) {
                self.max_reached = true;
                self.after_left = if (self.ctx_enabled and self.cfg.after > 0) self.cfg.after else 0;
                return;
            }
        }
        self.after_left = if (self.ctx_enabled and self.cfg.after > 0) self.cfg.after else 0;
    }

    fn trailingBlock(self: *Searcher, data: []const u8, from: usize, abs: u64) !void {
        if (self.after_left <= 0 or self.out_quiet or !self.ctx_enabled) {
            self.stop = true;
            return;
        }
        var p = from;
        self.group_open = true;
        while (self.after_left > 0 and p < data.len) {
            const le = lineEnd(data, p);
            try self.contextPrint(data, p, le, self.lineNoAt(data, p), abs);
            p = if (le < data.len) le + 1 else data.len;
            self.after_left -= 1;
        }
        if (self.after_left <= 0) self.stop = true;
    }
};

fn fileError(ctx: *Ctx, io: Stdio, sr: *Searcher, name: []const u8, reason: []const u8) void {
    _ = ctx;
    if (sr.cfg.no_messages) return;
    common.errFmt(io, "grep", "{s}: {s}", .{ name, reason });
}

pub fn run(ctx: *Ctx, argv: []const []const u8, io: Stdio) u8 {
    return runImpl(ctx, argv, io) catch |e| common.finish(e, "grep", io);
}

const RunState = struct {
    status_error: bool = false,
    matched_any: bool = false,
    quit: bool = false,
};

fn runImpl(ctx: *Ctx, argv: []const []const u8, io: Stdio) common.IoError!u8 {
    var pr = parseArgs(ctx.alloc, argv, io.err, true) catch return error.OutOfMemory;
    defer pr.deinit(ctx.alloc);
    if (!pr.ok) return 2;
    var cfg = pr.cfg;
    if (cfg.list_match or cfg.list_nomatch or cfg.quiet) cfg.count = false;
    if (cfg.max_count != null and cfg.max_count.? == 0 and !cfg.list_nomatch) return 1;
    var operands = pr.operands.items;
    if (!pr.explicit_pattern) {
        if (operands.len == 0) {
            common.errRaw(io, "Usage: grep [OPTION]... PATTERNS [FILE]...\nTry 'grep --help' for more information.\n", .{});
            return 2;
        }
        try pr.patterns.append(ctx.alloc, operands[0]);
        operands = operands[1..];
    }
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(ctx.alloc);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| ctx.alloc.free(o);
        owned.deinit(ctx.alloc);
    }
    for (pr.patterns.items) |pat| {
        var it = std.mem.splitScalar(u8, pat, '\n');
        while (it.next()) |one| try pats.append(ctx.alloc, one);
    }
    for (pr.pattern_files.items) |pf| {
        var in: common.Input = .{};
        in.open(ctx, io, pf) catch |e| {
            common.errFmt(io, "grep", "{s}: {s}", .{ pf, common.errnoText(e) });
            return 2;
        };
        defer in.close();
        var all: std.ArrayList(u8) = .empty;
        defer all.deinit(ctx.alloc);
        while (common.nextChunk(in.r) catch null) |c| try all.appendSlice(ctx.alloc, c);
        if (all.items.len > 0) {
            var body = all.items;
            if (body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
            const dup = try ctx.alloc.dupe(u8, body);
            try owned.append(ctx.alloc, dup);
            var it = std.mem.splitScalar(u8, dup, '\n');
            while (it.next()) |one| try pats.append(ctx.alloc, one);
        }
    }
    if (cfg.invert and !cfg.line and !cfg.word and !cfg.list_nomatch and pr.patterns.items.len == 1 and pr.pattern_files.items.len == 0 and pr.patterns.items[0].len == 0) return 1;
    const utf8 = common.isUtf8Locale(ctx.env);
    var re_opt: ?*regex.Regex = null;
    if (pats.items.len > 0) {
        re_opt = regex.Regex.compile(ctx.alloc, pats.items, regexOptions(cfg, utf8)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                common.errFmt(io, "grep", "invalid regular expression", .{});
                return 2;
            },
        };
    }
    defer if (re_opt) |r| r.deinit();

    const recursive = cfg.dirs == .recurse;
    var with_filename: bool = undefined;
    var dir_decides = false;
    if (cfg.with_filename) |w| {
        with_filename = w;
    } else if (operands.len > 1) {
        with_filename = true;
    } else if (recursive) {
        with_filename = false;
        dir_decides = true;
    } else with_filename = false;
    if (cfg.quiet) cfg.no_messages = cfg.no_messages;
    const dev_null_out = ctx.out_null and !cfg.list_nomatch;
    if (dev_null_out) cfg.count = false;
    const done_on_match0 = cfg.list_match or cfg.list_nomatch or cfg.quiet or dev_null_out;
    const out_quiet0 = cfg.count or done_on_match0;
    var sr: Searcher = .{
        .ctx = ctx,
        .io = io,
        .cfg = cfg,
        .re = re_opt,
        .utf8 = utf8,
        .with_filename = with_filename,
        .out_quiet0 = out_quiet0,
        .done_on_match0 = done_on_match0,
        .ctx_enabled = cfg.after >= 0 or cfg.before >= 0,
    };
    defer sr.deinit();

    var rs: RunState = .{};
    var any_selected = false;
    var default_dot = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.alloc);
    if (operands.len == 0) {
        if (recursive) {
            try files.append(ctx.alloc, "");
            default_dot = true;
        } else try files.append(ctx.alloc, "-");
    } else try files.appendSlice(ctx.alloc, operands);

    var w: Walker = .{
        .ctx = ctx,
        .io = io,
        .sr = &sr,
        .rs = &rs,
        .pr = &pr,
        .any_selected = &any_selected,
        .dir_decides = dir_decides,
    };
    for (files.items) |f| {
        if (rs.quit) break;
        try w.topLevel(f, default_dot);
    }
    if (any_selected and cfg.quiet) return 0;
    if (rs.status_error) return 2;
    return if (any_selected) 0 else 1;
}

const Walker = struct {
    ctx: *Ctx,
    io: Stdio,
    sr: *Searcher,
    rs: *RunState,
    pr: *Parsed,
    any_selected: *bool,
    dir_decides: bool,
    listed_any: bool = false,

    fn excludedFile(self: *Walker, name: []const u8, command_line: bool) bool {
        if (self.pr.includes.items.len > 0) {
            var ok = false;
            for (self.pr.includes.items) |pat| {
                const m = if (command_line) common.globMatchSuffix(pat, name) else common.globMatch(pat, std.fs.path.basename(name), .{});
                if (m) ok = true;
            }
            if (!ok) return true;
        }
        for (self.pr.excludes.items) |pat| {
            const m = if (command_line) common.globMatchSuffix(pat, name) else common.globMatch(pat, std.fs.path.basename(name), .{});
            if (m) return true;
        }
        return false;
    }

    fn excludedDir(self: *Walker, name: []const u8, command_line: bool) bool {
        for (self.pr.exclude_dirs.items) |pat| {
            const m = if (command_line) common.globMatchSuffix(pat, name) else common.globMatch(pat, std.fs.path.basename(name), .{});
            if (m) return true;
        }
        return false;
    }

    fn topLevel(self: *Walker, path: []const u8, default_dot: bool) common.IoError!void {
        const cfg = self.sr.cfg;
        if (common.isDashOperand(path)) {
            self.sr.name = cfg.label;
            try self.searchStdin();
            return;
        }
        const display = path;
        if (default_dot) {
            try self.walkDir("", true);
            return;
        }
        const kind = common.statKind(self.ctx, path, true);
        if (kind == null) {
            self.rs.status_error = true;
            const e = fileOpenErr(self.ctx, path);
            if (!cfg.no_messages) common.errFmt(self.io, "grep", "{s}: {s}", .{ display, e });
            return;
        }
        if (kind.? == .directory) {
            switch (cfg.dirs) {
                .skip => return,
                .read => {
                    try self.searchFile(path);
                    return;
                },
                .recurse => {
                    if (self.dir_decides) self.sr.with_filename = true;
                    if (self.pr.exclude_dirs.items.len > 0 and self.excludedDir(path, true)) return;
                    var p = path;
                    if (p.len > 1 and p[p.len - 1] == '/') {
                        var q = p;
                        while (q.len > 1 and q[q.len - 1] == '/') q = q[0 .. q.len - 1];
                        p = q;
                    }
                    try self.walkDir(p, false);
                    return;
                },
            }
        }
        if ((self.pr.includes.items.len > 0 or self.pr.excludes.items.len > 0) and self.excludedFile(path, true)) return;
        try self.searchFile(path);
    }

    fn walkDir(self: *Walker, path: []const u8, implicit: bool) common.IoError!void {
        const alloc = self.ctx.alloc;
        var list = common.readDirList(self.ctx, if (implicit) "." else path) catch |e| {
            self.rs.status_error = true;
            if (!self.sr.cfg.no_messages) common.errFmt(self.io, "grep", "{s}: {s}", .{ if (implicit) "." else path, common.errnoText(e) });
            return;
        };
        defer list.deinit(alloc);
        for (list.items.items) |ent| {
            if (self.rs.quit) return;
            const child = if (implicit)
                try alloc.dupe(u8, ent.name)
            else if (path.len > 0 and path[path.len - 1] == '/')
                try std.fmt.allocPrint(alloc, "{s}{s}", .{ path, ent.name })
            else
                try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, ent.name });
            defer alloc.free(child);
            var kind = ent.kind;
            const cfg = self.sr.cfg;
            if (kind == .sym_link) {
                if (!cfg.deref) continue;
                kind = common.statKind(self.ctx, child, true) orelse {
                    self.rs.status_error = true;
                    if (!cfg.no_messages) common.errFmt(self.io, "grep", "{s}: No such file or directory", .{child});
                    continue;
                };
            } else if (kind == .unknown) {
                kind = common.statKind(self.ctx, child, false) orelse continue;
            }
            switch (kind) {
                .directory => {
                    if (self.pr.exclude_dirs.items.len > 0 and self.excludedDir(ent.name, false)) continue;
                    try self.walkDir(child, false);
                },
                .file => {
                    if ((self.pr.includes.items.len > 0 or self.pr.excludes.items.len > 0) and self.excludedFile(ent.name, false)) continue;
                    try self.searchFile(child);
                },
                else => {},
            }
        }
    }

    fn fileOpenErr(ctx: *Ctx, path: []const u8) []const u8 {
        var pb: [common.path_max]u8 = undefined;
        const full = common.joinCwd(&pb, ctx.cwd, path) catch return "File name too long";
        const f = Io.Dir.cwd().openFile(ctx.io, full, .{}) catch |e| return common.errnoText(e);
        f.close(ctx.io);
        return "No such file or directory";
    }

    fn searchStdin(self: *Walker) common.IoError!void {
        try self.finishFile(self.io.in, null);
    }

    fn searchFile(self: *Walker, path: []const u8) common.IoError!void {
        var in: common.Input = .{};
        in.open(self.ctx, self.io, path) catch |e| {
            self.rs.status_error = true;
            if (!self.sr.cfg.no_messages) common.errFmt(self.io, "grep", "{s}: {s}", .{ path, common.errnoText(e) });
            return;
        };
        defer in.close();
        self.sr.name = path;
        try self.finishFile(in.r, &in);
    }

    fn finishFile(self: *Walker, r: *Io.Reader, in: ?*common.Input) common.IoError!void {
        const sr = self.sr;
        const cfg = sr.cfg;
        sr.count = 0;
        sr.out_quiet = sr.out_quiet0;
        sr.done_on_match = sr.done_on_match0;
        sr.binary_active = false;
        sr.nlines_first_null = 0;
        sr.enc_error = false;
        sr.after_left = 0;
        sr.last_out_line = 0;
        sr.carry.clearRetainingCapacity();
        sr.carry_lines = 0;
        sr.stop = false;
        sr.max_reached = false;
        sr.cursor_line = 1;
        const max = cfg.max_count;
        var skip_file = false;
        if (max != null and max.? == 0) skip_file = true;
        var read_failed = false;
        if (!skip_file) {
            var br: BlockReader = .{ .r = r, .alloc = self.ctx.alloc, .io = self.ctx.io };
            if (in) |i| {
                if (!i.stdin and i.src.kind == .file) br.file = i.src.file;
            }
            defer br.deinit();
            var line_base: u64 = 1;
            while (try br.next()) |blk| {
                if (cfg.binary != .text and blk.has_nul and !sr.binary_active) {
                    if (cfg.binary == .without_match) {
                        sr.count = 0;
                        break;
                    }
                    sr.binary_active = true;
                    sr.nlines_first_null = sr.count;
                    if (!cfg.count) {
                        sr.done_on_match = true;
                        sr.out_quiet = true;
                    }
                }
                try sr.processBlock(blk.data, blk.abs_off, blk.final, line_base);
                line_base += common.countByte(blk.data, '\n');
                if (blk.final and blk.data.len > 0 and blk.data[blk.data.len - 1] != '\n') line_base += 1;
                if (sr.stop) break;
            }
            if (br.read_err) read_failed = true;
        }
        if (read_failed) {
            self.rs.status_error = true;
            if (!cfg.no_messages) {
                const reason = if (in) |i| i.readErr() else "Input/output error";
                common.errFmt(self.io, "grep", "{s}: {s}", .{ sr.name, reason });
            }
        }
        const w = self.io.out;
        if (cfg.count) {
            if (sr.with_filename) {
                try common.put(w, sr.name);
                if (cfg.null_name) try common.putByte(w, 0) else try common.putByte(w, ':');
            }
            try common.putUint(w, sr.count);
            try common.putByte(w, '\n');
        }
        const status_match = sr.count > 0;
        if (status_match) self.any_selected.* = true;
        if (cfg.list_match and status_match or cfg.list_nomatch and !status_match) {
            if (cfg.list_nomatch) self.listed_any = true;
            try common.put(w, sr.name);
            try common.putByte(w, if (cfg.null_name) 0 else '\n');
        }
        if (cfg.binary == .binary and !sr.out_quiet0 and !cfg.no_messages and (sr.enc_error or (sr.binary_active and sr.nlines_first_null < sr.count))) {
            common.errFmt(self.io, "grep", "{s}: binary file matches", .{sr.name});
        }
        if (cfg.quiet and status_match) self.rs.quit = true;
    }
};

fn t(argv: []const []const u8, input: []const u8, want: []const u8, status: u8) !void {
    return common.expectRun(run, argv, input, want, status);
}

test "grep basics" {
    try t(&.{ "grep", "foo" }, "a\nfoo\nb\nfoo2\n", "foo\nfoo2\n", 0);
    try t(&.{ "grep", "-n", "foo" }, "a\nfoo\nb\nfoo2\n", "2:foo\n4:foo2\n", 0);
    try t(&.{ "grep", "-c", "foo" }, "a\nfoo\nb\nfoo2\n", "2\n", 0);
    try t(&.{ "grep", "-v", "foo" }, "a\nfoo\nb\nfoo2\n", "a\nb\n", 0);
    try t(&.{ "grep", "-vn", "foo" }, "a\nfoo\nb\nfoo2\n", "1:a\n3:b\n", 0);
    try t(&.{ "grep", "zzz" }, "a\nb\n", "", 1);
    try t(&.{ "grep", "-i", "FOO" }, "a\nfoo\n", "foo\n", 0);
    try t(&.{ "grep", "-o", "o\\+" }, "foo\nboo x\n", "oo\noo\n", 0);
    try t(&.{ "grep", "-w", "foo" }, "foo bar\nfoobar\nbar foo\n", "foo bar\nbar foo\n", 0);
    try t(&.{ "grep", "-x", "foo" }, "foo\nfoo bar\n", "foo\n", 0);
    try t(&.{ "grep", "-E", "a|b" }, "a\nc\nb\n", "a\nb\n", 0);
    try t(&.{ "grep", "-F", "a.b" }, "a.b\naxb\n", "a.b\n", 0);
    try t(&.{ "grep", "-m1", "a" }, "a\na\n", "a\n", 0);
    try t(&.{ "grep", "-e", "a", "-e", "b" }, "a\nc\nb\n", "a\nb\n", 0);
}

test "grep context" {
    try t(&.{ "grep", "-n", "-A1", "foo" }, "a\nb\nfoo\nc\nd\ne\nfoo2\nf\n", "3:foo\n4-c\n--\n7:foo2\n8-f\n", 0);
    try t(&.{ "grep", "-n", "-B1", "foo" }, "a\nb\nfoo\nc\nd\ne\nfoo2\nf\n", "2-b\n3:foo\n--\n6-e\n7:foo2\n", 0);
    try t(&.{ "grep", "-C1", "foo" }, "a\nfoo\nb\nfoo\nc\n", "a\nfoo\nb\nfoo\nc\n", 0);
    try t(&.{ "grep", "-m1", "-A2", "foo" }, "a\nfoo\nc\nd\ne\n", "foo\nc\nd\n", 0);
}

test "grep supports" {
    try std.testing.expect(supports(&.{ "grep", "-rn", "foo", "." }));
    try std.testing.expect(supports(&.{ "grep", "-E", "a|b", "f" }));
    try std.testing.expect(!supports(&.{ "grep", "-P", "x" }));
    try std.testing.expect(!supports(&.{ "grep", "-E", "(a)\\1" }));
    try std.testing.expect(!supports(&.{ "grep", "--color=always", "x" }));
    try std.testing.expect(!supports(&.{"grep"}));
}

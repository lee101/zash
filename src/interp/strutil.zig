const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn char_len(utf8: bool, s: []const u8) usize {
    if (!utf8) return s.len;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += seq_len(s[i], s.len - i);
        n += 1;
    }
    return n;
}

pub fn seq_len(first: u8, avail: usize) usize {
    const l: usize = if (first < 0x80) 1 else if (first >= 0xf0) 4 else if (first >= 0xe0) 3 else if (first >= 0xc0) 2 else 1;
    return @min(l, avail);
}

pub fn char_offset(utf8: bool, s: []const u8, chars: usize) usize {
    if (!utf8) return @min(chars, s.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < chars) {
        i += seq_len(s[i], s.len - i);
        n += 1;
    }
    return i;
}

pub fn needs_quote_plain(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', ',', '@', '%', '+', '=', '~' => {},
            else => return true,
        }
    }
    return false;
}

pub fn has_ctl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

pub fn single_quote(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\\''");
        } else try out.append(a, c);
    }
    try out.append(a, '\'');
}

pub fn ansi_quote(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.appendSlice(a, "$'");
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(a, "\\'"),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\t' => try out.appendSlice(a, "\\t"),
            '\r' => try out.appendSlice(a, "\\r"),
            0x07 => try out.appendSlice(a, "\\a"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0b => try out.appendSlice(a, "\\v"),
            0x0c => try out.appendSlice(a, "\\f"),
            0x1b => try out.appendSlice(a, "\\E"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try out.print(a, "\\{o:0>3}", .{c});
                } else try out.append(a, c);
            },
        }
    }
    try out.append(a, '\'');
}

pub fn quote_for_at_q(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (s.len == 0) return out.appendSlice(a, "''");
    if (has_ctl(s)) return ansi_quote(a, out, s);
    return single_quote(a, out, s);
}

pub fn quote_xtrace(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (s.len == 0) return out.appendSlice(a, "''");
    if (has_ctl(s)) return ansi_quote(a, out, s);
    var plain = true;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', ',', '@', '%', '+', '=', '~', '^', '#', '*', '?', '[', ']', '(', ')', '{', '}', '!', '<', '>', '&', ';', '|', '$', '`', '"', '\\', ' ', '\'' => {
                switch (c) {
                    '*', '?', '[', ']', '(', ')', '{', '}', '!', '<', '>', '&', ';', '|', '$', '`', '"', '\\', ' ', '\'', '#', '^' => plain = false,
                    else => {},
                }
            },
            else => plain = false,
        }
    }
    if (plain) return out.appendSlice(a, s);
    return single_quote(a, out, s);
}

pub fn quote_printf_q(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (s.len == 0) return out.appendSlice(a, "''");
    if (has_ctl(s)) return ansi_quote(a, out, s);
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', ',', '@', '%', '+', '=', '~' => try out.append(a, c),
            else => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
        }
    }
}

fn hexval(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn put_utf8(a: Allocator, out: *std.ArrayList(u8), cp: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(@min(cp, 0x10ffff)), &buf) catch {
        try out.append(a, '?');
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

pub const Escaped = struct { consumed: usize, stop: bool = false };

pub fn ansi_escape(a: Allocator, out: *std.ArrayList(u8), s: []const u8, i_in: usize, allow_c: bool) Allocator.Error!Escaped {
    var i = i_in;
    const c = s[i];
    i += 1;
    switch (c) {
        'a' => try out.append(a, 7),
        'b' => try out.append(a, 8),
        'e', 'E' => try out.append(a, 27),
        'f' => try out.append(a, 12),
        'n' => try out.append(a, 10),
        'r' => try out.append(a, 13),
        't' => try out.append(a, 9),
        'v' => try out.append(a, 11),
        '\\' => try out.append(a, '\\'),
        '\'' => try out.append(a, '\''),
        '"' => try out.append(a, '"'),
        '?' => try out.append(a, '?'),
        '0'...'7' => {
            var v: u32 = c - '0';
            var n: usize = 1;
            while (n < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (n += 1) {
                v = v * 8 + (s[i] - '0');
                i += 1;
            }
            try out.append(a, @truncate(v));
        },
        'x' => {
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 2 and i < s.len) : (n += 1) {
                const h = hexval(s[i]) orelse break;
                v = v * 16 + h;
                i += 1;
            }
            if (n == 0) {
                try out.appendSlice(a, "\\x");
            } else try out.append(a, @truncate(v));
        },
        'u', 'U' => {
            const max: usize = if (c == 'u') 4 else 8;
            var v: u32 = 0;
            var n: usize = 0;
            while (n < max and i < s.len) : (n += 1) {
                const h = hexval(s[i]) orelse break;
                v = v *% 16 +% h;
                i += 1;
            }
            if (n == 0) {
                try out.append(a, '\\');
                try out.append(a, c);
            } else try put_utf8(a, out, v);
        },
        'c' => {
            if (allow_c and i < s.len) {
                const ch = s[i];
                i += 1;
                try out.append(a, if (ch == '?') 0x7f else ch & 0x1f);
            } else {
                try out.appendSlice(a, "\\c");
            }
        },
        else => {
            try out.append(a, '\\');
            try out.append(a, c);
        },
    }
    return .{ .consumed = i - i_in };
}

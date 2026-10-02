const std = @import("std");
const tables = @import("unicode_tables.zig");

fn inRanges(ranges: []const [2]u21, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub fn isPrint(cp: u32) bool {
    return inRanges(&tables.print_ranges, cp);
}

pub fn width(cp: u32) u2 {
    if (inRanges(&tables.width0_ranges, cp)) return 0;
    if (inRanges(&tables.width2_ranges, cp)) return 2;
    return 1;
}

pub fn isSpace(cp: u32) bool {
    return switch (cp) {
        9...13, 32, 0x1680, 0x2000...0x2006, 0x2008...0x200a, 0x2028, 0x2029, 0x205f, 0x3000 => true,
        else => false,
    };
}

pub fn isNbsp(cp: u32) bool {
    return cp == 0xa0 or cp == 0x2007 or cp == 0x202f or cp == 0x2060;
}

pub const Decoded = union(enum) {
    ok: struct { cp: u32, len: u3 },
    invalid,
    incomplete,
};

pub fn decode(s: []const u8) Decoded {
    const b0 = s[0];
    if (b0 < 0x80) return .{ .ok = .{ .cp = b0, .len = 1 } };
    var need: u3 = 0;
    var lo: u8 = 0x80;
    var hi: u8 = 0xbf;
    var cp: u32 = 0;
    switch (b0) {
        0xc2...0xdf => {
            need = 2;
            cp = b0 & 0x1f;
        },
        0xe0...0xef => {
            need = 3;
            cp = b0 & 0x0f;
            if (b0 == 0xe0) lo = 0xa0;
            if (b0 == 0xed) hi = 0x9f;
        },
        0xf0...0xf7 => {
            need = 4;
            cp = b0 & 0x07;
            if (b0 == 0xf0) lo = 0x90;
        },
        0xf8...0xfb => {
            need = 5;
            cp = b0 & 0x03;
            if (b0 == 0xf8) lo = 0x88;
        },
        0xfc, 0xfd => {
            need = 6;
            cp = b0 & 0x01;
            if (b0 == 0xfc) lo = 0x84;
        },
        else => return .invalid,
    }
    var i: usize = 1;
    while (i < need) : (i += 1) {
        if (i >= s.len) return .incomplete;
        const b = s[i];
        if (i == 1) {
            if (b < lo or b > hi) return .invalid;
        } else if (b < 0x80 or b > 0xbf) return .invalid;
        cp = (cp << 6) | (b & 0x3f);
    }
    return .{ .ok = .{ .cp = cp, .len = need } };
}

pub fn isAscii(buf: []const u8) bool {
    const L = 32;
    const V = @Vector(L, u8);
    var i: usize = 0;
    var acc: V = @splat(0);
    while (buf.len - i >= L) : (i += L) {
        const c: V = buf[i..][0..L].*;
        acc |= c;
    }
    if (@reduce(.Or, acc) >= 0x80) return false;
    while (i < buf.len) : (i += 1) if (buf[i] >= 0x80) return false;
    return true;
}

test "decode" {
    try std.testing.expect(decode("a").ok.cp == 'a');
    try std.testing.expect(decode("\xc3\xa9").ok.cp == 0xe9);
    try std.testing.expect(decode("\xc3(") == .invalid);
    try std.testing.expect(decode("\xc3") == .incomplete);
    try std.testing.expect(decode("\xe0\x80\x80") == .invalid);
    try std.testing.expect(decode("\xed\xa0\x80") == .invalid);
    try std.testing.expect(decode("\xf0\x9f\x98\x80").ok.cp == 0x1f600);
    try std.testing.expect(decode("\xf4\x90\x80\x80").ok.cp == 0x110000);
    try std.testing.expect(decode("\xff") == .invalid);
}

test "tables" {
    try std.testing.expect(isPrint('a'));
    try std.testing.expect(!isPrint(0x85));
    try std.testing.expectEqual(@as(u2, 2), width(0x65e5));
    try std.testing.expectEqual(@as(u2, 0), width(0x301));
    try std.testing.expectEqual(@as(u2, 1), width('a'));
    try std.testing.expect(isAscii("hello world, this is a long enough ascii string for vectors"));
    try std.testing.expect(!isAscii("hello world, this is a long enough ascii string for vectors \xc3"));
}

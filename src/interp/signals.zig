const std = @import("std");

pub const names = [_][]const u8{
    "EXIT",   "HUP",  "INT",    "QUIT", "ILL",   "TRAP", "ABRT", "BUS",
    "FPE",    "KILL", "USR1",   "SEGV", "USR2",  "PIPE", "ALRM", "TERM",
    "STKFLT", "CHLD", "CONT",   "STOP", "TSTP",  "TTIN", "TTOU", "URG",
    "XCPU",   "XFSZ", "VTALRM", "PROF", "WINCH", "IO",   "PWR",  "SYS",
};

pub fn parse(spec: []const u8) ?u32 {
    if (spec.len == 0) return null;
    if (std.ascii.isDigit(spec[0])) {
        const n = std.fmt.parseInt(u32, spec, 10) catch return null;
        if (n > 64) return null;
        return n;
    }
    var s = spec;
    var upper_buf: [32]u8 = undefined;
    if (s.len > upper_buf.len) return null;
    for (s, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    s = upper_buf[0..s.len];
    if (std.mem.startsWith(u8, s, "SIG")) s = s[3..];
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, s)) return @intCast(i);
    }
    if (std.mem.eql(u8, s, "IOT")) return 6;
    if (std.mem.eql(u8, s, "CLD")) return 17;
    if (std.mem.eql(u8, s, "POLL")) return 29;
    if (std.mem.eql(u8, s, "RTMIN")) return 34;
    if (std.mem.eql(u8, s, "RTMAX")) return 64;
    if (std.mem.startsWith(u8, s, "RTMIN+")) {
        const k = std.fmt.parseInt(u32, s[6..], 10) catch return null;
        if (34 + k > 64) return null;
        return 34 + k;
    }
    if (std.mem.startsWith(u8, s, "RTMAX-")) {
        const k = std.fmt.parseInt(u32, s[6..], 10) catch return null;
        if (k > 30) return null;
        return 64 - k;
    }
    return null;
}

pub fn name_of(n: u32, buf: []u8) []const u8 {
    if (n < names.len) return names[n];
    if (n >= 34 and n <= 64) {
        if (n == 34) return "RTMIN";
        if (n == 64) return "RTMAX";
        if (n < 49) return std.fmt.bufPrint(buf, "RTMIN+{d}", .{n - 34}) catch "?";
        return std.fmt.bufPrint(buf, "RTMAX-{d}", .{64 - n}) catch "?";
    }
    return "?";
}

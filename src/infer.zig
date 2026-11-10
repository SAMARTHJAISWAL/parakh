//! Value classification: what does a single CSV cell look like?
//!
//! Each non-null cell is classified on its own. The column type is decided
//! later from the counts (see `profile.zig`), which is what lets parakh say
//! "this is a float column with 3 values that are not numbers".

const std = @import("std");

pub const Kind = enum {
    integer,
    float,
    boolean,
    date,
    datetime,
    string,

    pub fn family(k: Kind) Family {
        return switch (k) {
            .integer, .float => .numeric,
            .date, .datetime => .temporal,
            .boolean => .boolean,
            .string => .string,
        };
    }
};

pub const Family = enum { numeric, temporal, boolean, string };

pub const Value = union(enum) {
    null,
    integer: f64,
    float: f64,
    boolean,
    date,
    datetime,
    string,

    pub fn kind(v: Value) ?Kind {
        return switch (v) {
            .null => null,
            .integer => .integer,
            .float => .float,
            .boolean => .boolean,
            .date => .date,
            .datetime => .datetime,
            .string => .string,
        };
    }
};

const null_tokens = [_][]const u8{ "na", "n/a", "#n/a", "null", "none", "nan", "nil", "-", "--", "?" };
const bool_tokens = [_][]const u8{ "true", "false", "yes", "no" };

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

/// Classify an already-trimmed cell.
pub fn classify(s: []const u8) Value {
    if (s.len == 0) return .null;
    const c0 = s[0];
    // Most cells in real data are numbers or dates: try those first and only
    // fall back to the token tables for short alphabetic cells.
    if (std.ascii.isDigit(c0) or c0 == '-' or c0 == '+' or c0 == '.') {
        if (parseNumber(s)) |n| return if (n.is_integer) .{ .integer = n.value } else .{ .float = n.value };
        if (s.len >= 10 and std.ascii.isDigit(c0)) {
            if (isDate(s)) return .date;
            if (isDateTime(s)) return .datetime;
        }
    }
    if (s.len <= 5) {
        var lower: [5]u8 = undefined;
        const l = std.ascii.lowerString(&lower, s);
        if (s.len <= 4) {
            for (null_tokens) |tok| if (std.mem.eql(u8, l, tok)) return .null;
        }
        for (bool_tokens) |tok| if (std.mem.eql(u8, l, tok)) return .boolean;
    }
    return .string;
}

pub const Number = struct { value: f64, is_integer: bool };

/// Accepts: optional sign, digits with optional `,` thousands groups,
/// optional fraction, optional exponent. Rejects hex, inf/nan, leading
/// zeros in multi-digit integers (zip codes and IDs stay strings).
pub fn parseNumber(s: []const u8) ?Number {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const int_start = i;
    var digits: usize = 0;
    var grouped = false;
    var group_len: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            digits += 1;
            group_len += 1;
        } else if (c == ',') {
            // 1,234,567 — first group 1..3 digits, later groups exactly 3.
            if (digits == 0 or (grouped and group_len != 3) or (!grouped and group_len > 3)) return null;
            grouped = true;
            group_len = 0;
        } else break;
    }
    if (grouped and group_len != 3) return null;
    const int_digits = digits;
    var is_integer = true;
    if (i < s.len and s[i] == '.') {
        is_integer = false;
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        is_integer = false;
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == exp_start) return null;
    }
    if (i != s.len) return null;
    if (int_digits > 1 and s[int_start] == '0' and is_integer) return null;

    if (fastDecimal(s)) |v| return .{ .value = v, .is_integer = is_integer };
    var buf: [128]u8 = undefined;
    var src = s;
    if (grouped) {
        if (s.len > buf.len) return null;
        var n: usize = 0;
        for (s) |c| if (c != ',') {
            buf[n] = c;
            n += 1;
        };
        src = buf[0..n];
    }
    const v = std.fmt.parseFloat(f64, src) catch return null;
    if (!std.math.isFinite(v)) return null;
    return .{ .value = v, .is_integer = is_integer };
}

const pow10 = blk: {
    var p: [16]f64 = undefined;
    var x: f64 = 1;
    for (&p) |*e| {
        e.* = x;
        x *= 10;
    }
    break :blk p;
};

/// Clinger's fast path: a decimal with at most 15 significant digits and no
/// exponent is `mantissa / 10^k` with both operands exact in f64, so a
/// single correctly-rounded division gives the correctly-rounded result.
/// Returns null for anything else (the caller falls back to parseFloat).
fn fastDecimal(s: []const u8) ?f64 {
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-' or s[0] == '+') {
        neg = s[0] == '-';
        i = 1;
    }
    var mant: u64 = 0;
    var digits: usize = 0;
    var frac: usize = 0;
    var seen_dot = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            mant = mant * 10 + (c - '0');
            digits += 1;
            if (seen_dot) frac += 1;
            if (digits > 15) return null;
        } else if (c == '.' and !seen_dot) {
            seen_dot = true;
        } else if (c == ',') {
            continue; // grouping already validated by the caller
        } else return null;
    }
    const v = @as(f64, @floatFromInt(mant)) / pow10[frac];
    return if (neg) -v else v;
}

fn digitsAt(s: []const u8, start: usize, n: usize) ?u32 {
    if (start + n > s.len) return null;
    var v: u32 = 0;
    for (s[start .. start + n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(y: u32, m: u32) u32 {
    return switch (m) {
        4, 6, 9, 11 => 30,
        2 => if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) 29 else 28,
        else => 31,
    };
}

/// YYYY-MM-DD or YYYY/MM/DD, calendar-valid.
pub fn isDate(s: []const u8) bool {
    return s.len == 10 and datePrefix(s);
}

fn datePrefix(s: []const u8) bool {
    if (s.len < 10) return false;
    const sep = s[4];
    if ((sep != '-' and sep != '/') or s[7] != sep) return false;
    const y = digitsAt(s, 0, 4) orelse return false;
    const m = digitsAt(s, 5, 2) orelse return false;
    const d = digitsAt(s, 8, 2) orelse return false;
    return m >= 1 and m <= 12 and d >= 1 and d <= daysInMonth(y, m);
}

/// Date + ('T' | ' ') + HH:MM[:SS[.fraction]] + optional Z or ±HH:MM.
pub fn isDateTime(s: []const u8) bool {
    if (s.len < 16 or !datePrefix(s)) return false;
    if (s[10] != 'T' and s[10] != ' ') return false;
    const hh = digitsAt(s, 11, 2) orelse return false;
    if (s[13] != ':') return false;
    const mm = digitsAt(s, 14, 2) orelse return false;
    if (hh > 23 or mm > 59) return false;
    var i: usize = 16;
    if (i < s.len and s[i] == ':') {
        const ss = digitsAt(s, i + 1, 2) orelse return false;
        if (ss > 60) return false;
        i += 3;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const start = i;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == start) return false;
        }
    }
    if (i == s.len) return true;
    if (s[i] == 'Z') return i + 1 == s.len;
    if (s[i] == '+' or s[i] == '-') {
        if (s.len - i == 6 and s[i + 3] == ':') {
            return digitsAt(s, i + 1, 2) != null and digitsAt(s, i + 4, 2) != null;
        }
        return s.len - i == 5 and digitsAt(s, i + 1, 4) != null;
    }
    return false;
}

/// Days since 1970-01-01 (fractional for datetimes, time zone ignored), for
/// any string `isDate` or `isDateTime` accepts.
pub fn epochDays(s: []const u8) f64 {
    const y: i64 = digitsAt(s, 0, 4).?;
    const m: i64 = digitsAt(s, 5, 2).?;
    const d: i64 = digitsAt(s, 8, 2).?;
    // Howard Hinnant's days_from_civil.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    var days: f64 = @floatFromInt(era * 146097 + doe - 719468);
    if (s.len >= 16) {
        const hh: f64 = @floatFromInt(digitsAt(s, 11, 2).?);
        const mm: f64 = @floatFromInt(digitsAt(s, 14, 2).?);
        days += (hh * 60 + mm) / 1440;
    }
    return days;
}

const t = std.testing;

test "epochDays" {
    try t.expectEqual(@as(f64, 0), epochDays("1970-01-01"));
    try t.expectEqual(@as(f64, 19723), epochDays("2024-01-01"));
    try t.expectEqual(@as(f64, -1), epochDays("1969-12-31"));
    try t.expectEqual(@as(f64, 19723.5), epochDays("2024-01-01T12:00:00Z"));
}

test "nulls" {
    for ([_][]const u8{ "", "NA", "n/a", "NULL", "None", "NaN", "-", "#N/A" }) |s|
        try t.expect(classify(s) == .null);
}

test "fast path agrees with parseFloat" {
    var prng = std.Random.DefaultPrng.init(11);
    var buf: [64]u8 = undefined;
    for (0..20_000) |_| {
        const r = prng.random();
        const x = (r.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(r.intRangeAtMost(i32, -3, 9)));
        const s = try std.fmt.bufPrint(&buf, "{d:.6}", .{x});
        try t.expectEqual(try std.fmt.parseFloat(f64, s), parseNumber(s).?.value);
    }
}

test "numbers" {
    try t.expectEqual(@as(f64, 42), classify("42").integer);
    try t.expectEqual(@as(f64, -3.5), classify("-3.5").float);
    try t.expectEqual(@as(f64, 1234567), classify("1,234,567").integer);
    try t.expectEqual(@as(f64, 0.001), classify(".001").float);
    try t.expectEqual(@as(f64, 1.5e3), classify("1.5e3").float);
    try t.expectEqual(@as(f64, 0), classify("0").integer);
}

test "things that are not numbers" {
    for ([_][]const u8{ "007", "1,23", "12,3456", "0x1F", "inf", "1.2.3", "1e", "$5", "5%", ",5" }) |s|
        try t.expect(classify(s) == .string);
}

test "booleans" {
    for ([_][]const u8{ "true", "FALSE", "Yes", "no" }) |s| try t.expect(classify(s) == .boolean);
}

test "dates and datetimes" {
    try t.expect(classify("2024-02-29") == .date);
    try t.expect(classify("2023-02-29") == .string);
    try t.expect(classify("2024/13/01") == .string);
    try t.expect(classify("2024-06-01T12:30") == .datetime);
    try t.expect(classify("2024-06-01 12:30:45.123Z") == .datetime);
    try t.expect(classify("2024-06-01T12:30:45+05:30") == .datetime);
    try t.expect(classify("2024-06-01T25:30") == .string);
}

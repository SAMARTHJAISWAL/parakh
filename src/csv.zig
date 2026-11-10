//! Streaming RFC 4180 CSV reader over a `std.Io.Reader`.
//!
//! Works directly on the reader's buffer: plain runs of bytes are found with a
//! vectorised scan and copied in one go, so the per-byte state machine only
//! runs on delimiters, quotes and line ends. Handles quoted fields with
//! embedded delimiters, newlines and doubled quotes; LF, CRLF and bare CR line
//! endings; a UTF-8 byte-order mark; and blank lines. Malformed input is read
//! leniently and counted rather than rejected.

const std = @import("std");
const Io = std.Io;

pub const Parser = struct {
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    delimiter: u8,

    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(usize) = .empty,
    fields: std.ArrayList([]const u8) = .empty,

    state: State = .field_start,
    skip_lf: bool = false,
    started: bool = false,
    in_record: bool = false,
    field_quoted: bool = false,

    /// Total bytes consumed from the reader (after decompression, if any).
    bytes_read: u64 = 0,
    /// Fields with a stray quote, text after a closing quote, or an
    /// unterminated quote at end of input.
    malformed: u64 = 0,

    const State = enum { field_start, unquoted, quoted, quote_in_quoted };

    pub fn init(gpa: std.mem.Allocator, reader: *Io.Reader, delimiter: u8) Parser {
        return .{ .gpa = gpa, .reader = reader, .delimiter = delimiter };
    }

    pub fn deinit(self: *Parser) void {
        self.bytes.deinit(self.gpa);
        self.ends.deinit(self.gpa);
        self.fields.deinit(self.gpa);
    }

    /// Next record, or null at end of input. The returned slices stay valid
    /// until the next call.
    pub fn next(self: *Parser) !?[]const []const u8 {
        if (!self.started) {
            self.started = true;
            if (self.reader.peek(3)) |head| {
                if (std.mem.eql(u8, head, "\xEF\xBB\xBF")) {
                    self.reader.toss(3);
                    self.bytes_read += 3;
                }
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }
        }
        self.bytes.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
        self.in_record = false;
        self.field_quoted = false;

        while (true) {
            const chunk = self.reader.buffered();
            if (chunk.len == 0) {
                self.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return self.finishAtEof(),
                    else => |e| return e,
                };
                continue;
            }
            const res = try self.scan(chunk);
            self.reader.toss(res.consumed);
            self.bytes_read += res.consumed;
            if (res.record_done) {
                if (self.isBlankRecord()) {
                    self.ends.clearRetainingCapacity();
                    self.bytes.clearRetainingCapacity();
                    self.in_record = false;
                    continue;
                }
                return try self.buildFields();
            }
        }
    }

    const ScanResult = struct { consumed: usize, record_done: bool };

    fn scan(self: *Parser, chunk: []const u8) !ScanResult {
        const gpa = self.gpa;
        const delim = self.delimiter;
        var i: usize = 0;
        while (i < chunk.len) {
            const c = chunk[i];
            if (self.skip_lf) {
                self.skip_lf = false;
                if (c == '\n') {
                    i += 1;
                    continue;
                }
            }
            switch (self.state) {
                .field_start => {
                    self.in_record = true;
                    self.field_quoted = false;
                    if (c == '"') {
                        self.state = .quoted;
                        self.field_quoted = true;
                        i += 1;
                    } else if (c == delim) {
                        try self.endField();
                        i += 1;
                    } else if (c == '\n' or c == '\r') {
                        try self.endField();
                        self.skip_lf = c == '\r';
                        return .{ .consumed = i + 1, .record_done = true };
                    } else {
                        self.state = .unquoted;
                    }
                },
                .unquoted => {
                    // Fast path: copy everything up to the next special byte.
                    const rest = chunk[i..];
                    const stop = indexOfSpecial(rest, delim);
                    if (stop > 0) {
                        try self.bytes.appendSlice(gpa, rest[0..stop]);
                        i += stop;
                        continue;
                    }
                    if (c == delim) {
                        try self.endField();
                        self.state = .field_start;
                        i += 1;
                    } else if (c == '\n' or c == '\r') {
                        try self.endField();
                        self.state = .field_start;
                        self.skip_lf = c == '\r';
                        return .{ .consumed = i + 1, .record_done = true };
                    } else {
                        // A quote in the middle of an unquoted field: keep it.
                        self.malformed += 1;
                        try self.bytes.append(gpa, c);
                        i += 1;
                    }
                },
                .quoted => {
                    const rest = chunk[i..];
                    const q = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                    try self.bytes.appendSlice(gpa, rest[0..q]);
                    i += q;
                    if (q < rest.len) {
                        self.state = .quote_in_quoted;
                        i += 1;
                    }
                },
                .quote_in_quoted => {
                    if (c == '"') {
                        try self.bytes.append(gpa, '"');
                        self.state = .quoted;
                        i += 1;
                    } else if (c == delim) {
                        try self.endField();
                        self.state = .field_start;
                        i += 1;
                    } else if (c == '\n' or c == '\r') {
                        try self.endField();
                        self.state = .field_start;
                        self.skip_lf = c == '\r';
                        return .{ .consumed = i + 1, .record_done = true };
                    } else {
                        // Text after the closing quote: "abc"def
                        self.malformed += 1;
                        self.state = .unquoted;
                    }
                },
            }
        }
        return .{ .consumed = chunk.len, .record_done = false };
    }

    fn endField(self: *Parser) !void {
        try self.ends.append(self.gpa, self.bytes.items.len);
    }

    fn isBlankRecord(self: *const Parser) bool {
        return self.ends.items.len == 1 and self.ends.items[0] == 0 and !self.field_quoted;
    }

    fn finishAtEof(self: *Parser) !?[]const []const u8 {
        if (!self.in_record) return null;
        if (self.state == .quoted) self.malformed += 1;
        try self.endField();
        self.state = .field_start;
        self.in_record = false;
        if (self.isBlankRecord()) return null;
        return try self.buildFields();
    }

    fn buildFields(self: *Parser) ![]const []const u8 {
        self.fields.clearRetainingCapacity();
        try self.fields.ensureTotalCapacity(self.gpa, self.ends.items.len);
        var start: usize = 0;
        for (self.ends.items) |end| {
            self.fields.appendAssumeCapacity(self.bytes.items[start..end]);
            start = end;
        }
        return self.fields.items;
    }
};

/// Index of the first delimiter, quote, CR or LF, or `s.len`. Checks 16 bytes
/// at a time with SIMD compares.
fn indexOfSpecial(s: []const u8, delim: u8) usize {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= s.len) : (i += 16) {
        const v: V = s[i..][0..16].*;
        const hit = (v == @as(V, @splat(delim))) | (v == @as(V, @splat('"'))) |
            (v == @as(V, @splat('\n'))) | (v == @as(V, @splat('\r')));
        const mask: u16 = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == delim or c == '"' or c == '\n' or c == '\r') return i;
    }
    return s.len;
}

/// Guess the delimiter from the first line of `sample`: the candidate that
/// occurs most often outside quotes. Ties prefer the order , \t ; |
pub fn sniffDelimiter(sample: []const u8) u8 {
    const candidates = [_]u8{ ',', '\t', ';', '|' };
    var counts: [candidates.len]usize = @splat(0);
    var in_quotes = false;
    for (sample) |c| {
        if (c == '"') in_quotes = !in_quotes;
        if (in_quotes) continue;
        if (c == '\n' or c == '\r') break;
        for (candidates, 0..) |cand, k| {
            if (c == cand) counts[k] += 1;
        }
    }
    var best: usize = 0;
    for (counts, 0..) |n, k| {
        if (n > counts[best]) best = k;
    }
    return candidates[best];
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn parseAll(input: []const u8, delim: u8) !struct { rows: [][][]u8, malformed: u64 } {
    const gpa = t.allocator;
    var r: Io.Reader = .fixed(input);
    var p = Parser.init(gpa, &r, delim);
    defer p.deinit();
    var rows: std.ArrayList([][]u8) = .empty;
    while (try p.next()) |rec| {
        const row = try gpa.alloc([]u8, rec.len);
        for (rec, row) |f, *dst| dst.* = try gpa.dupe(u8, f);
        try rows.append(gpa, row);
    }
    return .{ .rows = try rows.toOwnedSlice(gpa), .malformed = p.malformed };
}

fn freeRows(rows: [][][]u8) void {
    for (rows) |row| {
        for (row) |f| t.allocator.free(f);
        t.allocator.free(row);
    }
    t.allocator.free(rows);
}

fn expectRows(input: []const u8, expected: []const []const []const u8) !void {
    const res = try parseAll(input, ',');
    defer freeRows(res.rows);
    try t.expectEqual(expected.len, res.rows.len);
    for (expected, res.rows) |exp_row, got_row| {
        try t.expectEqual(exp_row.len, got_row.len);
        for (exp_row, got_row) |e, g| try t.expectEqualStrings(e, g);
    }
}

test "simple rows, trailing newline optional" {
    try expectRows("a,b,c\n1,2,3\n", &.{ &.{ "a", "b", "c" }, &.{ "1", "2", "3" } });
    try expectRows("a,b\n1,2", &.{ &.{ "a", "b" }, &.{ "1", "2" } });
}

test "quoted fields with delimiters, newlines and doubled quotes" {
    try expectRows(
        "name,quote\n\"Doe, Jane\",\"She said \"\"hi\"\"\nthen left\"\n",
        &.{ &.{ "name", "quote" }, &.{ "Doe, Jane", "She said \"hi\"\nthen left" } },
    );
}

test "CRLF, bare CR and blank lines" {
    try expectRows("a,b\r\n1,2\r\n\r\n3,4\r5,6\n", &.{ &.{ "a", "b" }, &.{ "1", "2" }, &.{ "3", "4" }, &.{ "5", "6" } });
}

test "empty fields and a quoted empty record" {
    try expectRows("a,,c\n,,\n\"\"\n", &.{ &.{ "a", "", "c" }, &.{ "", "", "" }, &.{""} });
}

test "byte-order mark is skipped" {
    try expectRows("\xEF\xBB\xBFid,v\n1,2\n", &.{ &.{ "id", "v" }, &.{ "1", "2" } });
}

test "malformed quotes are read leniently and counted" {
    const res = try parseAll("a,b\nx\"y,\"ok\"z\n\"open", ',');
    defer freeRows(res.rows);
    try t.expectEqual(@as(usize, 3), res.rows.len);
    try t.expectEqualStrings("x\"y", res.rows[1][0]);
    try t.expectEqualStrings("okz", res.rows[1][1]);
    try t.expectEqualStrings("open", res.rows[2][0]);
    try t.expectEqual(@as(u64, 3), res.malformed);
}

test "long fields cross the SIMD fast path" {
    const piece = "abcdefghijklmnopqrstuvwxyz0123456789";
    const long = piece ++ piece ++ piece ++ piece;
    try expectRows(long ++ "," ++ long ++ "\n", &.{&.{ long, long }});
}

test "fields split across tiny reader buffers" {
    const input = "id,text\n1,\"hello, \"\"world\"\"\"\r\n2,plain\n";
    // A file-like reader with a 4-byte buffer forces every boundary case.
    var src: Io.Reader = .fixed(input);
    var buf: [4]u8 = undefined;
    var limited = src.limited(.unlimited, &buf);
    var p = Parser.init(t.allocator, &limited.interface, ',');
    defer p.deinit();
    _ = (try p.next()).?;
    const r1 = (try p.next()).?;
    try t.expectEqualStrings("hello, \"world\"", r1[1]);
    const r2 = (try p.next()).?;
    try t.expectEqualStrings("plain", r2[1]);
    try t.expect((try p.next()) == null);
}

test "sniffing" {
    try t.expectEqual(@as(u8, ','), sniffDelimiter("a,b,c\n1;2;3;4;5"));
    try t.expectEqual(@as(u8, ';'), sniffDelimiter("a;b;\"c,d,e\"\n"));
    try t.expectEqual(@as(u8, '\t'), sniffDelimiter("a\tb\tc"));
    try t.expectEqual(@as(u8, '|'), sniffDelimiter("a|b"));
    try t.expectEqual(@as(u8, ','), sniffDelimiter("single"));
}

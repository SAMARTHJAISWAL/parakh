//! Report → text. Three formats: an aligned terminal table (with optional
//! ANSI colour and sparklines), GitHub-flavoured Markdown, and JSON.

const std = @import("std");
const Io = std.Io;
const profile = @import("profile.zig");
const Report = profile.Report;
const ColumnReport = profile.ColumnReport;

pub const Format = enum { table, markdown, json };

pub const Style = struct {
    color: bool = false,
    /// Wall time, shown in the table header when known.
    elapsed_ns: ?u64 = null,
};

pub fn write(w: *Io.Writer, report: Report, format: Format, style: Style) !void {
    switch (format) {
        .json => {
            try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, w);
            try w.writeByte('\n');
        },
        .table => try writeTable(w, report, style),
        .markdown => try writeMarkdown(w, report),
    }
}

// ------------------------------------------------------------ formatting

const Ansi = struct {
    on: bool,
    fn s(a: Ansi, code: []const u8) []const u8 {
        return if (a.on) code else "";
    }
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
};

fn typeColor(type_name: []const u8) []const u8 {
    const map = .{
        .{ "integer", Ansi.cyan },     .{ "float", Ansi.blue },     .{ "date", Ansi.magenta },
        .{ "datetime", Ansi.magenta }, .{ "boolean", Ansi.yellow }, .{ "string", Ansi.green },
        .{ "mixed", Ansi.red },        .{ "empty", Ansi.dim },
    };
    inline for (map) |m| if (std.mem.eql(u8, type_name, m[0])) return m[1];
    return "";
}

/// Human number: thousands separators for integers, a few significant
/// decimals otherwise, scientific notation for the very large or small.
pub fn fmtNum(buf: []u8, x: f64) []const u8 {
    const ax = @abs(x);
    if (x == @trunc(x) and ax < 1e15) {
        return fmtInt(buf, @intFromFloat(x));
    }
    if (ax >= 1e9 or ax < 1e-4) {
        return std.fmt.bufPrint(buf, "{e:.2}", .{x}) catch "?";
    }
    const digits: usize = if (ax >= 1000) 1 else if (ax >= 1) 2 else 4;
    const raw = switch (digits) {
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{x}),
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{x}),
        else => std.fmt.bufPrint(buf, "{d:.4}", .{x}),
    } catch return "?";
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '0') end -= 1;
    if (end > 0 and raw[end - 1] == '.') end -= 1;
    if (ax >= 1000) {
        // Re-group the integer part.
        const dot = std.mem.indexOfScalar(u8, raw[0..end], '.') orelse end;
        var tmp: [64]u8 = undefined;
        const int_part = fmtInt(&tmp, @intFromFloat(@trunc(x)));
        const frac = raw[dot..end];
        if (int_part.len + frac.len > buf.len) return raw[0..end];
        var out: [96]u8 = undefined;
        @memcpy(out[0..int_part.len], int_part);
        @memcpy(out[int_part.len..][0..frac.len], frac);
        const n = int_part.len + frac.len;
        @memcpy(buf[0..n], out[0..n]);
        return buf[0..n];
    }
    return raw[0..end];
}

pub fn fmtInt(buf: []u8, v: i64) []const u8 {
    var digits: [32]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{@abs(v)}) catch return "?";
    var n: usize = 0;
    if (v < 0) {
        buf[0] = '-';
        n = 1;
    }
    for (plain, 0..) |c, i| {
        if (i > 0 and (plain.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// 1234 → "1,234"; 98123 → "98,123"; 1234567 → "1.23M".
fn fmtCount(buf: []u8, v: u64) []const u8 {
    if (v >= 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.2}B", .{@as(f64, @floatFromInt(v)) / 1e9}) catch "?";
    if (v >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.2}M", .{@as(f64, @floatFromInt(v)) / 1e6}) catch "?";
    return fmtInt(buf, @intCast(v));
}

fn fmtBytes(buf: []u8, v: u64) []const u8 {
    const f: f64 = @floatFromInt(v);
    if (v >= 1 << 30) return std.fmt.bufPrint(buf, "{d:.2} GiB", .{f / (1 << 30)}) catch "?";
    if (v >= 1 << 20) return std.fmt.bufPrint(buf, "{d:.1} MiB", .{f / (1 << 20)}) catch "?";
    if (v >= 1 << 10) return std.fmt.bufPrint(buf, "{d:.1} KiB", .{f / (1 << 10)}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{v}) catch "?";
}

fn fmtPct(buf: []u8, ratio: f64) []const u8 {
    if (ratio == 0) return "0%";
    if (ratio < 0.001) return "<0.1%";
    return std.fmt.bufPrint(buf, "{d:.1}%", .{ratio * 100}) catch "?";
}

fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Longest prefix of `s` that fits in `max` codepoints.
fn truncate(s: []const u8, max: usize) []const u8 {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var n: usize = 0;
    while (n < max) : (n += 1) {
        _ = it.nextCodepointSlice() orelse return s;
    }
    return s[0..it.i];
}

const spark = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn writeSparkline(w: *Io.Writer, hist: []const u64) !void {
    var max: u64 = 0;
    for (hist) |b| max = @max(max, b);
    for (hist) |b| {
        if (b == 0) {
            try w.writeAll(" ");
            continue;
        }
        const level = if (max == 0) 0 else (b * (spark.len - 1) + max - 1) / max;
        try w.writeAll(spark[@intCast(level)]);
    }
}

// ------------------------------------------------------------ cells

/// One rendered row of the summary table, as plain strings.
const Row = struct {
    idx: []const u8,
    name: []const u8,
    type: []const u8,
    nulls: []const u8,
    distinct: []const u8,
    min: []const u8,
    mean: []const u8,
    p50: []const u8,
    max: []const u8,
};

fn buildRow(a: std.mem.Allocator, c: ColumnReport) !Row {
    var b: [96]u8 = undefined;
    var r: Row = .{
        .idx = try std.fmt.allocPrint(a, "{d}", .{c.index + 1}),
        .name = truncate(c.name, 28),
        .type = c.type,
        .nulls = try a.dupe(u8, fmtPct(&b, c.null_ratio)),
        .distinct = undefined,
        .min = "",
        .mean = "",
        .p50 = "",
        .max = "",
    };
    const d = fmtCount(&b, c.distinct);
    r.distinct = if (c.distinct_exact) try a.dupe(u8, d) else try std.fmt.allocPrint(a, "~{s}", .{d});
    if (c.numeric) |n| {
        r.min = try a.dupe(u8, fmtNum(&b, n.min));
        r.mean = try a.dupe(u8, fmtNum(&b, n.mean));
        const p = fmtNum(&b, n.p50);
        r.p50 = if (n.quantiles_exact) try a.dupe(u8, p) else try std.fmt.allocPrint(a, "~{s}", .{p});
        r.max = try a.dupe(u8, fmtNum(&b, n.max));
    } else if (c.temporal) |tm| {
        r.min = truncate(tm.min, 16);
        r.max = truncate(tm.max, 16);
    } else if (std.mem.eql(u8, c.type, "boolean")) {
        // min/max lengths say nothing useful about a boolean column.
    } else if (c.text) |tx| {
        r.min = try std.fmt.allocPrint(a, "len {d}", .{tx.min_length});
        r.max = try std.fmt.allocPrint(a, "len {d}", .{tx.max_length});
    }
    return r;
}

fn writeShape(w: *Io.Writer, c: ColumnReport, ansi: Ansi, max_width: usize) !void {
    if (c.numeric) |n| {
        try w.writeAll(ansi.s(Ansi.cyan));
        try writeSparkline(w, n.histogram);
        try w.writeAll(ansi.s(Ansi.reset));
        return;
    }
    if (c.temporal) |tm| {
        try w.writeAll(ansi.s(Ansi.magenta));
        try writeSparkline(w, tm.histogram);
        try w.writeAll(ansi.s(Ansi.reset));
        try w.print(" {s}{d:.0} days{s}", .{ ansi.s(Ansi.dim), tm.span_days, ansi.s(Ansi.reset) });
        return;
    }
    if (c.count > 1 and @as(f64, @floatFromInt(c.distinct)) >= 0.97 * @as(f64, @floatFromInt(c.count))) {
        try w.print("{s}all distinct{s}", .{ ansi.s(Ansi.dim), ansi.s(Ansi.reset) });
        return;
    }
    if (c.top_values.len > 0 and c.count >= 1000 and c.top_values[0].count * 200 < c.count) {
        // Even the most common value is under 0.5%: percentages say nothing.
        try w.print("{s}high cardinality{s}", .{ ansi.s(Ansi.dim), ansi.s(Ansi.reset) });
        return;
    }
    var used: usize = 0;
    var b: [32]u8 = undefined;
    for (c.top_values, 0..) |tv, i| {
        const pct = if (c.count == 0) 0 else @as(f64, @floatFromInt(tv.count)) / @as(f64, @floatFromInt(c.count + c.nulls));
        const label = truncate(tv.value, 18);
        const pct_s = std.fmt.bufPrint(&b, "{d:.0}%", .{pct * 100}) catch "?";
        const need = displayWidth(label) + 1 + pct_s.len + (if (i > 0) @as(usize, 3) else 0);
        if (used + need > max_width) {
            if (i > 0) try w.writeAll(" …");
            break;
        }
        if (i > 0) try w.print("{s} · {s}", .{ ansi.s(Ansi.dim), ansi.s(Ansi.reset) });
        try writeSanitized(w, label);
        try w.print(" {s}{s}{s}", .{ ansi.s(Ansi.dim), pct_s, ansi.s(Ansi.reset) });
        used += need;
    }
}

/// Control characters (embedded newlines, tabs, escapes) become spaces so a
/// cell can never break the table or inject terminal sequences.
fn writeSanitized(w: *Io.Writer, s: []const u8) !void {
    for (s) |ch| try w.writeByte(if (ch < 0x20 or ch == 0x7f) ' ' else ch);
}

fn pad(w: *Io.Writer, s: []const u8, width: usize, right: bool) !void {
    const n = displayWidth(s);
    const fill = if (width > n) width - n else 0;
    if (right) try w.splatByteAll(' ', fill);
    try writeSanitized(w, s);
    if (!right) try w.splatByteAll(' ', fill);
}

// ------------------------------------------------------------ table

fn writeHeaderLine(w: *Io.Writer, r: Report, ansi: Ansi, style: Style) !void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    try w.print("{s}parakh{s}  {s}{s}{s}  {s}·{s}  {s} rows × {d} columns  {s}·{s}  {s}", .{
        ansi.s(Ansi.bold),  ansi.s(Ansi.reset),
        ansi.s(Ansi.bold),  r.source,
        ansi.s(Ansi.reset), ansi.s(Ansi.dim),
        ansi.s(Ansi.reset), fmtInt(&b1, @intCast(r.rows)),
        r.column_count,     ansi.s(Ansi.dim),
        ansi.s(Ansi.reset), fmtBytes(&b2, r.bytes),
    });
    if (style.elapsed_ns) |ns| {
        const secs = @as(f64, @floatFromInt(ns)) / 1e9;
        const mbps = if (secs > 0) @as(f64, @floatFromInt(r.bytes)) / (1 << 20) / secs else 0;
        try w.print("  {s}·  {d:.2} s, {d:.0} MiB/s{s}", .{ ansi.s(Ansi.dim), secs, mbps, ansi.s(Ansi.reset) });
    }
    try w.writeAll("\n\n");
}

fn writeTable(w: *Io.Writer, r: Report, style: Style) !void {
    const ansi: Ansi = .{ .on = style.color };
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try writeHeaderLine(w, r, ansi, style);

    const rows = try a.alloc(Row, r.columns.len);
    for (r.columns, rows) |c, *row| row.* = try buildRow(a, c);

    const headers = Row{
        .idx = "#",
        .name = "column",
        .type = "type",
        .nulls = "nulls",
        .distinct = "distinct",
        .min = "min",
        .mean = "mean",
        .p50 = "median",
        .max = "max",
    };
    const fields = comptime std.meta.fieldNames(Row);
    var widths: [fields.len]usize = undefined;
    inline for (fields, 0..) |f, i| {
        widths[i] = displayWidth(@field(headers, f));
        for (rows) |row| widths[i] = @max(widths[i], displayWidth(@field(row, f)));
    }
    // Numbers align right; names and types align left.
    const right = [_]bool{ true, false, false, true, true, true, true, true, true };

    try w.writeAll(ansi.s(Ansi.dim));
    inline for (fields, 0..) |f, i| {
        try w.writeAll("  ");
        try pad(w, @field(headers, f), widths[i], right[i]);
    }
    try w.writeAll("  shape");
    try w.writeAll(ansi.s(Ansi.reset));
    try w.writeByte('\n');

    for (rows, r.columns) |row, c| {
        inline for (fields, 0..) |f, i| {
            try w.writeAll("  ");
            const is_name = comptime std.mem.eql(u8, f, "name");
            const is_type = comptime std.mem.eql(u8, f, "type");
            if (is_name) try w.writeAll(ansi.s(Ansi.bold));
            if (is_type) try w.writeAll(ansi.s(typeColor(c.type)));
            try pad(w, @field(row, f), widths[i], right[i]);
            if (is_name or is_type) try w.writeAll(ansi.s(Ansi.reset));
        }
        try w.writeAll("  ");
        try writeShape(w, c, ansi, 44);
        try w.writeByte('\n');
    }

    if (r.findings.len > 0) {
        try w.print("\n{s}findings{s}\n", .{ ansi.s(Ansi.bold), ansi.s(Ansi.reset) });
        var name_w: usize = 0;
        for (r.findings) |f| name_w = @max(name_w, displayWidth(truncate(f.column orelse "(file)", 28)));
        for (r.findings) |f| {
            const icon, const color = switch (f.severity) {
                .warn => .{ "!", Ansi.yellow },
                .info => .{ "i", Ansi.blue },
            };
            try w.print("  {s}{s}{s}  ", .{ ansi.s(color), icon, ansi.s(Ansi.reset) });
            try w.writeAll(ansi.s(Ansi.bold));
            try pad(w, truncate(f.column orelse "(file)", 28), name_w, false);
            try w.writeAll(ansi.s(Ansi.reset));
            try w.writeAll("  ");
            try writeSanitized(w, f.message);
            try w.writeByte('\n');
        }
    }
}

// ------------------------------------------------------------ markdown

fn mdEscape(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '|' => try w.writeAll("\\|"),
        '\n', '\r' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
}

fn writeMarkdown(w: *Io.Writer, r: Report) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;

    try w.print("## `{s}`\n\n{s} rows × {d} columns · {s}\n\n", .{
        r.source, fmtInt(&b1, @intCast(r.rows)), r.column_count, fmtBytes(&b2, r.bytes),
    });
    try w.writeAll("| # | column | type | nulls | distinct | min | mean | median | max | shape |\n");
    try w.writeAll("|--:|:--|:--|--:|--:|--:|--:|--:|--:|:--|\n");
    for (r.columns) |c| {
        const row = try buildRow(a, c);
        try w.print("| {s} | ", .{row.idx});
        try mdEscape(w, row.name);
        try w.print(" | {s} | {s} | {s} | ", .{ row.type, row.nulls, row.distinct });
        try mdEscape(w, row.min);
        try w.print(" | {s} | {s} | ", .{ row.mean, row.p50 });
        try mdEscape(w, row.max);
        try w.writeAll(" | ");
        var shape: Io.Writer.Allocating = .init(a);
        try writeShape(&shape.writer, c, .{ .on = false }, 44);
        try mdEscape(w, shape.written());
        try w.writeAll(" |\n");
    }
    if (r.findings.len > 0) {
        try w.writeAll("\n**Findings**\n\n");
        for (r.findings) |f| {
            const icon = switch (f.severity) {
                .warn => "⚠️",
                .info => "ℹ️",
            };
            try w.print("- {s} `", .{icon});
            try mdEscape(w, f.column orelse "(file)");
            try w.writeAll("`: ");
            try mdEscape(w, f.message);
            try w.writeByte('\n');
        }
    }
}

// ------------------------------------------------------------ tests

const t = std.testing;

test "fmtNum" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("1,234,567", fmtNum(&b, 1234567));
    try t.expectEqualStrings("-42", fmtNum(&b, -42));
    try t.expectEqualStrings("3.14", fmtNum(&b, 3.14159));
    try t.expectEqualStrings("0.5", fmtNum(&b, 0.5));
    try t.expectEqualStrings("12,345.7", fmtNum(&b, 12345.67));
    try t.expectEqualStrings("0", fmtNum(&b, 0));
}

test "fmtCount and fmtPct" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("999,999", fmtCount(&b, 999_999));
    try t.expectEqualStrings("1.50M", fmtCount(&b, 1_500_000));
    try t.expectEqualStrings("0%", fmtPct(&b, 0));
    try t.expectEqualStrings("12.5%", fmtPct(&b, 0.125));
}

test "truncate respects codepoints" {
    try t.expectEqualStrings("नम", truncate("नमस्ते", 2));
    try t.expectEqualStrings("abc", truncate("abc", 10));
}

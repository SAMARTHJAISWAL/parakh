//! End-to-end: fixture bytes → profileReader → every renderer.

const std = @import("std");
const Io = std.Io;
const parakh = @import("parakh");
const t = std.testing;

fn run(arena: std.mem.Allocator, bytes: []const u8, options: parakh.Options) !parakh.Report {
    var r: Io.Reader = .fixed(bytes);
    return parakh.profileReader(t.allocator, arena, &r, options);
}

fn column(rep: parakh.Report, name: []const u8) parakh.profile.ColumnReport {
    for (rep.columns) |c| if (std.mem.eql(u8, c.name, name)) return c;
    @panic("missing column");
}

fn hasFinding(rep: parakh.Report, col: ?[]const u8, needle: []const u8) bool {
    for (rep.findings) |f| {
        const same_col = if (col) |c| (f.column != null and std.mem.eql(u8, f.column.?, c)) else f.column == null;
        if (same_col and std.mem.indexOf(u8, f.message, needle) != null) return true;
    }
    return false;
}

test "messy orders: BOM, CRLF, quotes, embedded newline, ragged row" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try run(a.allocator(), @embedFile("fixtures/messy_orders.csv"), .{ .source = "messy_orders.csv" });

    try t.expectEqual(@as(u64, 12), rep.rows);
    try t.expectEqualStrings(",", rep.delimiter);
    try t.expectEqualStrings("order_id", rep.columns[0].name); // BOM stripped
    try t.expectEqual(@as(u64, 1), rep.ragged_rows);
    try t.expect(hasFinding(rep, null, "different number of fields"));

    const id = column(rep, "order_id");
    try t.expectEqualStrings("integer", id.type);
    try t.expect(hasFinding(rep, "order_id", "candidate key"));

    const amount = column(rep, "amount");
    try t.expectEqualStrings("float", amount.type); // 10 numbers, 1 word, 1 null
    try t.expectEqual(@as(u64, 1), amount.nulls);
    try t.expectEqual(@as(u64, 1), amount.anomalies);
    try t.expectEqualStrings("pending", amount.anomaly_example.?);
    try t.expect(hasFinding(rep, "amount", "1 value is not float"));

    const region = column(rep, "region");
    try t.expectEqualStrings("string", region.type);
    try t.expectEqual(@as(u64, 4), region.distinct); // " South " is trimmed
    try t.expectEqualStrings("North", region.top_values[0].value);
    try t.expectEqual(@as(u64, 4), region.top_values[0].count);
    try t.expect(hasFinding(rep, "region", "whitespace"));

    try t.expect(hasFinding(rep, "currency", "constant"));

    const shipped = column(rep, "shipped");
    try t.expectEqualStrings("boolean", shipped.type);

    const when = column(rep, "ordered_at");
    try t.expectEqualStrings("date", when.type);
    try t.expectEqualStrings("2024-01-03", when.temporal.?.min);
    try t.expectEqualStrings("2024-01-22", when.temporal.?.max);
    try t.expectEqual(@as(f64, 19), when.temporal.?.span_days);

    const notes = column(rep, "notes");
    try t.expect(notes.null_ratio > 0.5);
    try t.expect(hasFinding(rep, "notes", "missing"));
    // The embedded newline and doubled quotes survive parsing.
    var saw_multiline = false;
    var saw_quote = false;
    for (notes.top_values) |tv| {
        if (std.mem.eql(u8, tv.value, "line one\r\nline two")) saw_multiline = true;
        if (std.mem.eql(u8, tv.value, "said \"ok\"")) saw_quote = true;
    }
    try t.expect(saw_multiline and saw_quote);
}

test "sniffs semicolons and keeps old dates and big integers" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try run(a.allocator(), @embedFile("fixtures/semicolon_eu.csv"), .{});
    try t.expectEqualStrings(";", rep.delimiter);
    const pop = column(rep, "population");
    try t.expectEqualStrings("integer", pop.type);
    try t.expectEqual(@as(f64, 602046), pop.numeric.?.min);
    try t.expectEqual(@as(f64, 3124458), pop.numeric.?.max);
    try t.expectEqualStrings("0758-01-01", column(rep, "founded").temporal.?.min);
}

test "headerless TSV with datetimes" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try run(a.allocator(), @embedFile("fixtures/no_header.tsv"), .{ .has_header = false });
    try t.expectEqualStrings("tab", rep.delimiter);
    try t.expectEqual(@as(u64, 3), rep.rows);
    try t.expectEqualStrings("column_3", rep.columns[2].name);
    try t.expectEqualStrings("datetime", rep.columns[2].type);
}

test "empty input and header-only input" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const empty = try run(a.allocator(), "", .{});
    try t.expectEqual(@as(u64, 0), empty.rows);
    try t.expectEqual(@as(usize, 0), empty.column_count);
    const header_only = try run(a.allocator(), "a,b,c\n", .{});
    try t.expectEqual(@as(u64, 0), header_only.rows);
    try t.expectEqual(@as(usize, 3), header_only.column_count);
    try t.expectEqualStrings("empty", header_only.columns[0].type);
}

test "JSON output round-trips through std.json" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try run(a.allocator(), @embedFile("fixtures/messy_orders.csv"), .{});
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try parakh.render.write(&out.writer, rep, .json, .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqual(@as(i64, 12), root.get("rows").?.integer);
    const cols = root.get("columns").?.array;
    try t.expectEqual(@as(usize, 9), cols.items.len);
    try t.expectEqualStrings("order_id", cols.items[0].object.get("name").?.string);
    try t.expectEqualStrings("integer", cols.items[0].object.get("type").?.string);
}

test "table and markdown renderers produce every column" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try run(a.allocator(), @embedFile("fixtures/messy_orders.csv"), .{ .source = "messy_orders.csv" });
    inline for (.{ parakh.render.Format.table, parakh.render.Format.markdown }) |fmt| {
        var out: Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try parakh.render.write(&out.writer, rep, fmt, .{ .color = true });
        const text = out.written();
        for (rep.columns) |c| try t.expect(std.mem.indexOf(u8, text, c.name) != null);
        try t.expect(std.mem.indexOf(u8, text, "messy_orders.csv") != null);
        if (fmt == .markdown) {
            try t.expect(std.mem.indexOf(u8, text, "\x1b[") == null); // never ANSI in markdown
            try t.expect(std.mem.indexOf(u8, text, "| # | column |") != null);
        }
    }
}

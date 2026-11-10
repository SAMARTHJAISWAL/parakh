//! The profiler: feeds every cell of every row through a fixed set of
//! streaming sketches per column, then turns them into a `Report`.
//!
//! Memory per column is bounded regardless of row count:
//!   HyperLogLog (64 KiB) + exact distinct set (≤ 4096 hashes)
//!   + exact value buffer (≤ 4096 values) + KLL quantile sketch (k = 512)
//!   + Misra-Gries heavy hitters (64 counters).

const std = @import("std");
const Io = std.Io;
const csv = @import("csv.zig");
const infer = @import("infer.zig");
const HyperLogLog = @import("sketch/hll.zig").HyperLogLog;
const Distribution = @import("sketch/quantiles.zig").Distribution;
const TopK = @import("sketch/topk.zig").TopK;

pub const Options = struct {
    /// Treat the first record as column names.
    has_header: bool = true,
    /// Delimiter, or null to sniff it from the first line.
    delimiter: ?u8 = null,
    /// Top values reported per column.
    top_n: usize = 5,
    /// Name shown in the report.
    source: []const u8 = "<stdin>",
    /// When set, columns are profiled on worker tasks while the next batch
    /// of rows is parsed. Results are identical to the serial path.
    io: ?Io = null,
    /// Worker count for the parallel path (default: CPU count).
    threads: ?usize = null,
    /// Rows parsed per batch in the parallel path.
    batch_rows: usize = 8192,
};

pub const histogram_buckets = 16;
const exact_distinct_limit = 4096;
const topk_capacity = 64;
const example_max_len = 48;
/// A family needs more than this share of non-null values to define the
/// column type; values outside it are reported as anomalies.
const type_threshold = 0.5;

// ------------------------------------------------------------ report types

pub const NumericStats = struct {
    min: f64,
    max: f64,
    mean: f64,
    stddev: f64,
    sum: f64,
    p05: f64,
    p25: f64,
    p50: f64,
    p75: f64,
    p95: f64,
    quantiles_exact: bool,
    histogram: []const u64,
};

pub const TextStats = struct {
    min_length: u64,
    max_length: u64,
    mean_length: f64,
};

pub const TemporalStats = struct {
    min: []const u8,
    max: []const u8,
    span_days: f64,
    histogram: []const u64,
};

pub const TopValue = struct {
    value: []const u8,
    count: u64,
};

pub const ColumnReport = struct {
    index: usize,
    name: []const u8,
    type: []const u8,
    count: u64,
    nulls: u64,
    null_ratio: f64,
    distinct: u64,
    distinct_exact: bool,
    anomalies: u64,
    anomaly_example: ?[]const u8,
    padded: u64,
    numeric: ?NumericStats,
    temporal: ?TemporalStats,
    text: ?TextStats,
    top_values: []const TopValue,
    top_exact: bool,
};

pub const Severity = enum { info, warn };

pub const Finding = struct {
    severity: Severity,
    column: ?[]const u8,
    message: []const u8,
};

pub const Report = struct {
    source: []const u8,
    delimiter: []const u8,
    rows: u64,
    column_count: usize,
    bytes: u64,
    ragged_rows: u64,
    malformed_fields: u64,
    columns: []const ColumnReport,
    findings: []const Finding,
};

// ------------------------------------------------------------ accumulation

const kind_count = std.meta.fieldNames(infer.Kind).len;

const Column = struct {
    name: []const u8,
    nulls: u64 = 0,
    non_null: u64 = 0,
    padded: u64 = 0,
    kinds: [kind_count]u64 = @splat(0),
    examples: [kind_count]?[]const u8 = @splat(null),

    hll: HyperLogLog(16) = .{},
    exact: std.AutoHashMapUnmanaged(u64, void) = .empty,
    exact_overflow: bool = false,
    top: TopK = .init(topk_capacity),

    // numeric
    n_num: u64 = 0,
    mean: f64 = 0,
    m2: f64 = 0,
    sum: f64 = 0,
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    dist: Distribution = .{},

    // text
    len_min: u64 = std.math.maxInt(u64),
    len_max: u64 = 0,
    len_sum: u64 = 0,

    // temporal
    t_min: ?[]u8 = null,
    t_max: ?[]u8 = null,
    t_lo: f64 = std.math.inf(f64),
    t_hi: f64 = -std.math.inf(f64),
    t_dist: Distribution = .{},

    fn deinit(c: *Column, gpa: std.mem.Allocator) void {
        gpa.free(c.name);
        for (c.examples) |e| if (e) |s| gpa.free(s);
        c.exact.deinit(gpa);
        c.top.deinit(gpa);
        c.dist.deinit(gpa);
        c.t_dist.deinit(gpa);
        if (c.t_min) |s| gpa.free(s);
        if (c.t_max) |s| gpa.free(s);
    }

    fn add(c: *Column, gpa: std.mem.Allocator, raw: []const u8) !void {
        const v = infer.trim(raw);
        const value = infer.classify(v);
        const kind = value.kind() orelse {
            c.nulls += 1;
            return;
        };
        c.non_null += 1;
        if (v.len != raw.len) c.padded += 1;
        c.kinds[@backingInt(kind)] += 1;
        if (c.examples[@backingInt(kind)] == null) {
            c.examples[@backingInt(kind)] = try gpa.dupe(u8, v[0..@min(v.len, example_max_len)]);
        }

        const h = std.hash.Wyhash.hash(0x9E3779B97F4A7C15, v);
        c.hll.addHash(h);
        if (!c.exact_overflow) {
            try c.exact.put(gpa, h, {});
            if (c.exact.count() > exact_distinct_limit) {
                c.exact_overflow = true;
                c.exact.clearAndFree(gpa);
            }
        }
        try c.top.add(gpa, v);

        const len: u64 = std.unicode.utf8CountCodepoints(v) catch v.len;
        c.len_min = @min(c.len_min, len);
        c.len_max = @max(c.len_max, len);
        c.len_sum += len;

        switch (value) {
            .integer, .float => |x| try c.addNumber(gpa, x),
            .date, .datetime => try c.addTemporal(gpa, v),
            else => {},
        }
    }

    fn addNumber(c: *Column, gpa: std.mem.Allocator, x: f64) !void {
        // Welford's online mean and variance: numerically stable in one pass.
        c.n_num += 1;
        const delta = x - c.mean;
        c.mean += delta / @as(f64, @floatFromInt(c.n_num));
        c.m2 += delta * (x - c.mean);
        c.sum += x;
        c.min = @min(c.min, x);
        c.max = @max(c.max, x);
        try c.dist.add(gpa, x);
    }

    fn addTemporal(c: *Column, gpa: std.mem.Allocator, v: []const u8) !void {
        const days = infer.epochDays(v);
        c.t_lo = @min(c.t_lo, days);
        c.t_hi = @max(c.t_hi, days);
        try c.t_dist.add(gpa, days);
        // ISO-8601 sorts lexicographically.
        if (c.t_min == null or std.mem.order(u8, v, c.t_min.?) == .lt) {
            if (c.t_min) |s| gpa.free(s);
            c.t_min = try gpa.dupe(u8, v);
        }
        if (c.t_max == null or std.mem.order(u8, v, c.t_max.?) == .gt) {
            if (c.t_max) |s| gpa.free(s);
            c.t_max = try gpa.dupe(u8, v);
        }
    }

    fn familyCount(c: *const Column, f: infer.Family) u64 {
        var n: u64 = 0;
        for (c.kinds, 0..) |k, i| {
            if (@as(infer.Kind, @fromBackingInt(@intCast(i))).family() == f) n += k;
        }
        return n;
    }

    fn kindCount(c: *const Column, k: infer.Kind) u64 {
        return c.kinds[@backingInt(k)];
    }
};

pub const Profiler = struct {
    gpa: std.mem.Allocator,
    options: Options,
    columns: std.ArrayList(*Column) = .empty,
    rows: u64 = 0,
    ragged_rows: u64 = 0,
    header_seen: bool = false,
    /// Field count every row is expected to have (header width, or the
    /// first data row's width without a header).
    expected_width: ?usize = null,
    duplicate_names: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, options: Options) Profiler {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(p: *Profiler) void {
        for (p.columns.items) |c| {
            c.deinit(p.gpa);
            p.gpa.destroy(c);
        }
        p.columns.deinit(p.gpa);
        p.duplicate_names.deinit(p.gpa);
    }

    fn addColumn(p: *Profiler, name: []const u8) !void {
        const c = try p.gpa.create(Column);
        errdefer p.gpa.destroy(c);
        const owned = if (name.len == 0)
            try std.fmt.allocPrint(p.gpa, "column_{d}", .{p.columns.items.len + 1})
        else
            try p.gpa.dupe(u8, name);
        c.* = .{ .name = owned };
        // A column that appears late was missing (null) in every earlier row.
        c.nulls = p.rows;
        try p.columns.append(p.gpa, c);
    }

    /// Handle the header record. Returns true if `fields` was consumed as
    /// the header (and so is not a data row).
    fn takeHeader(p: *Profiler, fields: []const []const u8) !bool {
        if (p.header_seen) return false;
        p.header_seen = true;
        if (!p.options.has_header) return false;
        for (fields) |f| {
            const name = infer.trim(f);
            for (p.columns.items) |c| {
                if (name.len > 0 and std.mem.eql(u8, c.name, name)) {
                    try p.duplicate_names.append(p.gpa, c.name);
                    break;
                }
            }
            try p.addColumn(name);
        }
        p.expected_width = fields.len;
        return true;
    }

    /// Row-shape bookkeeping shared by the serial and parallel paths.
    fn noteWidth(p: *Profiler, width: usize) void {
        const expected = p.expected_width orelse width;
        p.expected_width = expected;
        if (width != expected) p.ragged_rows += 1;
    }

    fn ensureColumns(p: *Profiler, width: usize) !void {
        while (p.columns.items.len < width) try p.addColumn("");
    }

    /// Profile one record on the calling thread.
    pub fn addRecord(p: *Profiler, fields: []const []const u8) !void {
        if (try p.takeHeader(fields)) return;
        p.noteWidth(fields.len);
        try p.ensureColumns(fields.len);
        for (p.columns.items, 0..) |c, i| {
            if (i < fields.len) try c.add(p.gpa, fields[i]) else c.nulls += 1;
        }
        p.rows += 1;
    }

    /// Build the report. Every slice in it is allocated from `arena`.
    pub fn finish(p: *Profiler, arena: std.mem.Allocator, meta: struct {
        bytes: u64,
        malformed: u64,
        delimiter: u8,
    }) !Report {
        var findings: std.ArrayList(Finding) = .empty;
        const cols = try arena.alloc(ColumnReport, p.columns.items.len);
        for (p.columns.items, cols, 0..) |c, *out, i| {
            out.* = try p.columnReport(arena, c, i);
            try columnFindings(arena, &findings, out.*, p.rows);
        }
        for (p.duplicate_names.items) |name| {
            try findings.append(arena, .{
                .severity = .warn,
                .column = name,
                .message = "column name appears more than once in the header",
            });
        }
        if (p.ragged_rows > 0) try findings.append(arena, .{
            .severity = .warn,
            .column = null,
            .message = try std.fmt.allocPrint(arena, "{f} {s} a different number of fields than the header", .{ Grouped{ .n = p.ragged_rows }, plural(p.ragged_rows, "row has", "rows have") }),
        });
        if (meta.malformed > 0) try findings.append(arena, .{
            .severity = .warn,
            .column = null,
            .message = try std.fmt.allocPrint(arena, "{f} {s} stray or unbalanced quotes (read leniently)", .{ Grouped{ .n = meta.malformed }, plural(meta.malformed, "field has", "fields have") }),
        });

        return .{
            .source = try arena.dupe(u8, p.options.source),
            .delimiter = try delimiterName(arena, meta.delimiter),
            .rows = p.rows,
            .column_count = cols.len,
            .bytes = meta.bytes,
            .ragged_rows = p.ragged_rows,
            .malformed_fields = meta.malformed,
            .columns = cols,
            .findings = try findings.toOwnedSlice(arena),
        };
    }

    fn columnReport(p: *Profiler, arena: std.mem.Allocator, c: *Column, index: usize) !ColumnReport {
        const n = c.non_null;
        const total = n + c.nulls;

        // Decide the type: the majority family; the rest are anomalies.
        const families = [_]infer.Family{ .numeric, .temporal, .boolean, .string };
        var best = families[0];
        var best_n: u64 = 0;
        for (families) |f| {
            const fc = c.familyCount(f);
            if (fc > best_n) {
                best = f;
                best_n = fc;
            }
        }
        var type_name: []const u8 = "empty";
        var anomalies: u64 = 0;
        var anomaly_example: ?[]const u8 = null;
        if (n > 0) {
            const share = @as(f64, @floatFromInt(best_n)) / @as(f64, @floatFromInt(n));
            if (best != .string and share > type_threshold) {
                type_name = switch (best) {
                    .numeric => if (c.kindCount(.float) > 0) "float" else "integer",
                    .temporal => if (c.kindCount(.datetime) > 0) "datetime" else "date",
                    .boolean => "boolean",
                    .string => unreachable,
                };
                anomalies = n - best_n;
                for (c.examples, 0..) |ex, k| {
                    if (ex != null and @as(infer.Kind, @fromBackingInt(@intCast(k))).family() != best) {
                        anomaly_example = try arena.dupe(u8, ex.?);
                        break;
                    }
                }
            } else if (best == .string and share > type_threshold) {
                type_name = "string";
            } else {
                type_name = "mixed";
            }
        }

        const distinct: u64 = if (c.exact_overflow)
            @intFromFloat(@round(c.hll.estimate()))
        else
            c.exact.count();

        var numeric: ?NumericStats = null;
        if (c.n_num > 0 and (std.mem.eql(u8, type_name, "integer") or std.mem.eql(u8, type_name, "float"))) {
            const hist = try arena.alloc(u64, histogram_buckets);
            const summary = (try c.dist.summarize(p.gpa, c.min, c.max, hist)).?;
            const q = summary.quantiles;
            const var_n: f64 = if (c.n_num > 1) c.m2 / @as(f64, @floatFromInt(c.n_num - 1)) else 0;
            numeric = .{
                .min = c.min,
                .max = c.max,
                .mean = c.mean,
                .stddev = @sqrt(var_n),
                .sum = c.sum,
                .p05 = q[0],
                .p25 = q[1],
                .p50 = q[2],
                .p75 = q[3],
                .p95 = q[4],
                .quantiles_exact = summary.exact,
                .histogram = hist,
            };
        }

        var temporal: ?TemporalStats = null;
        if (c.t_min != null and (std.mem.eql(u8, type_name, "date") or std.mem.eql(u8, type_name, "datetime"))) {
            const hist = try arena.alloc(u64, histogram_buckets);
            _ = try c.t_dist.summarize(p.gpa, c.t_lo, c.t_hi, hist);
            temporal = .{
                .min = try arena.dupe(u8, c.t_min.?),
                .max = try arena.dupe(u8, c.t_max.?),
                .span_days = c.t_hi - c.t_lo,
                .histogram = hist,
            };
        }

        const text: ?TextStats = if (n > 0) .{
            .min_length = c.len_min,
            .max_length = c.len_max,
            .mean_length = @as(f64, @floatFromInt(c.len_sum)) / @as(f64, @floatFromInt(n)),
        } else null;

        const entries = try c.top.top(p.gpa, p.options.top_n);
        defer p.gpa.free(entries);
        const top = try arena.alloc(TopValue, entries.len);
        for (entries, top) |e, *o| o.* = .{ .value = try arena.dupe(u8, e.value), .count = e.count };

        return .{
            .index = index,
            .name = try arena.dupe(u8, c.name),
            .type = type_name,
            .count = n,
            .nulls = c.nulls,
            .null_ratio = if (total == 0) 0 else @as(f64, @floatFromInt(c.nulls)) / @as(f64, @floatFromInt(total)),
            .distinct = distinct,
            .distinct_exact = !c.exact_overflow,
            .anomalies = anomalies,
            .anomaly_example = anomaly_example,
            .padded = c.padded,
            .numeric = numeric,
            .temporal = temporal,
            .text = text,
            .top_values = top,
            .top_exact = c.top.isExact(),
        };
    }
};

fn columnFindings(arena: std.mem.Allocator, out: *std.ArrayList(Finding), c: ColumnReport, rows: u64) !void {
    const add = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(Finding), sev: Severity, col: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try o.append(a, .{ .severity = sev, .column = col, .message = try std.fmt.allocPrint(a, fmt, args) });
        }
    }.f;
    if (rows == 0) return;
    if (c.count == 0) {
        return add(arena, out, .warn, c.name, "every value is missing", .{});
    }
    if (c.null_ratio >= 0.5) {
        try add(arena, out, .warn, c.name, "{d:.1}% of values are missing", .{c.null_ratio * 100});
    }
    if (c.distinct == 1 and c.distinct_exact) {
        const v = if (c.top_values.len > 0) c.top_values[0].value else "";
        try add(arena, out, .info, c.name, "constant: every value is \"{s}\"", .{v});
    }
    const key_type = std.mem.eql(u8, c.type, "integer") or std.mem.eql(u8, c.type, "string");
    if (key_type and c.distinct_exact and c.distinct == rows and c.nulls == 0 and rows > 1) {
        try add(arena, out, .info, c.name, "unique in every row (candidate key)", .{});
    } else if (key_type and !c.distinct_exact and c.nulls == 0 and
        @as(f64, @floatFromInt(c.distinct)) >= 0.97 * @as(f64, @floatFromInt(rows)))
    {
        try add(arena, out, .info, c.name, "~unique in every row (likely key)", .{});
    }
    if (c.anomalies > 0) {
        try add(arena, out, .warn, c.name, "{f} {s} not {s}, e.g. \"{s}\"", .{ Grouped{ .n = c.anomalies }, plural(c.anomalies, "value is", "values are"), c.type, c.anomaly_example orelse "?" });
    }
    if (std.mem.eql(u8, c.type, "mixed")) {
        try add(arena, out, .warn, c.name, "no single type covers a majority of values", .{});
    }
    if (c.padded > 0) {
        try add(arena, out, .info, c.name, "{f} {s} leading or trailing whitespace", .{ Grouped{ .n = c.padded }, plural(c.padded, "value has", "values have") });
    }
}

/// 1992 → "1,992" for finding messages.
const Grouped = struct {
    n: u64,
    pub fn format(g: Grouped, w: *Io.Writer) Io.Writer.Error!void {
        var digits: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&digits, "{d}", .{g.n}) catch unreachable;
        for (s, 0..) |c, i| {
            if (i > 0 and (s.len - i) % 3 == 0) try w.writeByte(',');
            try w.writeByte(c);
        }
    }
};

fn plural(n: u64, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

fn delimiterName(arena: std.mem.Allocator, d: u8) ![]const u8 {
    return switch (d) {
        '\t' => "tab",
        else => arena.dupe(u8, &.{d}),
    };
}

// ------------------------------------------------------------ parallel

/// Freestanding targets (the browser build) profile on the calling thread.
const has_threads = !@import("builtin").single_threaded and @import("builtin").os.tag != .freestanding;

/// A batch of rows copied out of the parser: one byte arena plus offsets.
const Batch = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// End offset (into `bytes`) of every field, row after row.
    ends: std.ArrayList(usize) = .empty,
    /// Index into `ends` of each row's first field.
    starts: std.ArrayList(usize) = .empty,
    max_width: usize = 0,

    fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        b.bytes.deinit(gpa);
        b.ends.deinit(gpa);
        b.starts.deinit(gpa);
    }

    fn clear(b: *Batch) void {
        b.bytes.clearRetainingCapacity();
        b.ends.clearRetainingCapacity();
        b.starts.clearRetainingCapacity();
        b.max_width = 0;
    }

    fn push(b: *Batch, gpa: std.mem.Allocator, fields: []const []const u8) !void {
        try b.starts.append(gpa, b.ends.items.len);
        for (fields) |f| {
            try b.bytes.appendSlice(gpa, f);
            try b.ends.append(gpa, b.bytes.items.len);
        }
        b.max_width = @max(b.max_width, fields.len);
    }

    fn rowCount(b: *const Batch) usize {
        return b.starts.items.len;
    }

    fn get(b: *const Batch, row: usize, col: usize) ?[]const u8 {
        const first = b.starts.items[row];
        const end = if (row + 1 < b.starts.items.len) b.starts.items[row + 1] else b.ends.items.len;
        if (col >= end - first) return null;
        const idx = first + col;
        const lo = if (idx == 0) 0 else b.ends.items[idx - 1];
        return b.bytes.items[lo..b.ends.items[idx]];
    }
};

/// Profiles every `stride`-th column of a batch. Each column is owned by
/// exactly one worker per batch and batches run in order, so the result does
/// not depend on scheduling.
const Worker = struct {
    gpa: std.mem.Allocator,
    columns: []const *Column,
    batch: *const Batch,
    first: usize,
    stride: usize,
    err: ?anyerror = null,

    fn run(w: *Worker) void {
        w.process() catch |e| {
            w.err = e;
        };
    }

    fn process(w: *Worker) !void {
        var c = w.first;
        while (c < w.columns.len) : (c += w.stride) {
            const col = w.columns[c];
            for (0..w.batch.rowCount()) |r| {
                if (w.batch.get(r, c)) |v| try col.add(w.gpa, v) else col.nulls += 1;
            }
        }
    }
};

/// Double-buffered pipeline: the calling thread parses batch N+1 while the
/// workers profile batch N.
fn runParallel(p: *Profiler, parser: *csv.Parser, io: Io, options: Options) !void {
    const gpa = p.gpa;
    // One core stays with the parser; the Io pool also holds cpu - 1 workers.
    const cpus = options.threads orelse @max(1, (std.Thread.getCpuCount() catch 2) - 1);
    var batches: [2]Batch = .{ .{}, .{} };
    defer for (&batches) |*b| b.deinit(gpa);
    var workers: std.ArrayList(Worker) = .empty;
    defer workers.deinit(gpa);

    var group: Io.Group = .init;
    var pending = false;
    defer if (pending) group.cancel(io);

    var cur: usize = 0;
    while (true) {
        const b = &batches[cur];
        b.clear();
        while (b.rowCount() < options.batch_rows) {
            const rec = (try parser.next()) orelse break;
            if (try p.takeHeader(rec)) continue;
            p.noteWidth(rec.len);
            try b.push(gpa, rec);
        }

        if (pending) {
            pending = false;
            try group.await(io);
            for (workers.items) |w| if (w.err) |e| return e;
        }
        if (b.rowCount() == 0) break;

        // Safe: no worker is running, so the column list may grow.
        try p.ensureColumns(b.max_width);
        const n = @max(1, @min(cpus, p.columns.items.len));
        try workers.resize(gpa, n);
        for (workers.items, 0..) |*w, i| {
            w.* = .{ .gpa = gpa, .columns = p.columns.items, .batch = b, .first = i, .stride = n };
            group.async(io, Worker.run, .{w});
        }
        pending = true;
        p.rows += b.rowCount();
        cur ^= 1;
    }
}

// ------------------------------------------------------------ pipeline

/// Run the whole pipeline over a reader: sniff, parse, profile, report.
/// `gpa` holds working state; the returned report lives in `arena`.
pub fn profileReader(gpa: std.mem.Allocator, arena: std.mem.Allocator, reader: *Io.Reader, options: Options) !Report {
    const delimiter = options.delimiter orelse blk: {
        // Buffer enough of the stream to see the first line.
        while (std.mem.indexOfAny(u8, reader.buffered(), "\r\n") == null and
            reader.bufferedLen() < reader.buffer.len)
        {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
        }
        break :blk csv.sniffDelimiter(reader.buffered());
    };

    var parser = csv.Parser.init(gpa, reader, delimiter);
    defer parser.deinit();
    var profiler = Profiler.init(gpa, options);
    defer profiler.deinit();

    if (options.io != null and comptime has_threads) {
        try runParallel(&profiler, &parser, options.io.?, options);
    } else {
        while (try parser.next()) |record| try profiler.addRecord(record);
    }

    return profiler.finish(arena, .{
        .bytes = parser.bytes_read,
        .malformed = parser.malformed,
        .delimiter = delimiter,
    });
}

// ------------------------------------------------------------ tests

const t = std.testing;

fn profileString(arena: std.mem.Allocator, input: []const u8, options: Options) !Report {
    var r: Io.Reader = .fixed(input);
    return profileReader(t.allocator, arena, &r, options);
}

test "types, nulls and anomalies" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try profileString(a.allocator(),
        \\id,price,when,ok,note
        \\1,9.5,2024-01-03,true,hello
        \\2,10,2024-01-01,false,
        \\3,N/A,2024-02-01,yes,world
        \\4,12.25,2024-01-15,no,hello
    , .{});
    try t.expectEqual(@as(u64, 4), rep.rows);
    try t.expectEqual(@as(usize, 5), rep.column_count);
    const c = rep.columns;
    try t.expectEqualStrings("integer", c[0].type);
    try t.expectEqualStrings("float", c[1].type);
    try t.expectEqual(@as(u64, 1), c[1].nulls);
    try t.expectEqualStrings("date", c[2].type);
    try t.expectEqualStrings("2024-01-01", c[2].temporal.?.min);
    try t.expectEqualStrings("2024-02-01", c[2].temporal.?.max);
    try t.expectEqualStrings("boolean", c[3].type);
    try t.expectEqualStrings("string", c[4].type);
    try t.expectEqual(@as(u64, 2), c[4].distinct);
    try t.expectEqualStrings("hello", c[4].top_values[0].value);
    try t.expectEqual(@as(u64, 2), c[4].top_values[0].count);
}

test "numeric statistics are exact on small inputs" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try profileString(a.allocator(), "x\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", .{});
    const n = rep.columns[0].numeric.?;
    try t.expectEqual(@as(f64, 1), n.min);
    try t.expectEqual(@as(f64, 10), n.max);
    try t.expectEqual(@as(f64, 5.5), n.mean);
    try t.expectEqual(@as(f64, 55), n.sum);
    try t.expectApproxEqAbs(@as(f64, 3.02765), n.stddev, 1e-4);
    try t.expectEqual(@as(f64, 5.5), n.p50);
    try t.expect(n.quantiles_exact);
    var total: u64 = 0;
    for (n.histogram) |b| total += b;
    try t.expectEqual(@as(u64, 10), total);
}

test "type with a few anomalies is reported with an example" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendSlice(t.allocator, "amount\n");
    for (0..99) |i| try buf.print(t.allocator, "{d}\n", .{i});
    try buf.appendSlice(t.allocator, "twelve\n");
    const rep = try profileString(a.allocator(), buf.items, .{});
    const c = rep.columns[0];
    try t.expectEqualStrings("integer", c.type);
    try t.expectEqual(@as(u64, 1), c.anomalies);
    try t.expectEqualStrings("twelve", c.anomaly_example.?);
}

test "ragged rows, late columns and duplicate headers" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try profileString(a.allocator(), "a,a\n1,2\n3\n4,5,6\n", .{});
    try t.expectEqual(@as(usize, 3), rep.column_count);
    try t.expectEqualStrings("column_3", rep.columns[2].name);
    try t.expectEqual(@as(u64, 2), rep.columns[2].nulls);
    try t.expectEqual(@as(u64, 2), rep.ragged_rows);
    var saw_dup = false;
    for (rep.findings) |f| {
        if (std.mem.indexOf(u8, f.message, "more than once") != null) saw_dup = true;
    }
    try t.expect(saw_dup);
}

test "no header and sniffed semicolon delimiter" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const rep = try profileString(a.allocator(), "1;x\n2;y\n", .{ .has_header = false });
    try t.expectEqualStrings(";", rep.delimiter);
    try t.expectEqual(@as(u64, 2), rep.rows);
    try t.expectEqualStrings("column_1", rep.columns[0].name);
}

test "parallel pipeline matches the serial result exactly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendSlice(t.allocator, "id,group,value,when,extra\n");
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    for (0..30_000) |i| {
        try buf.print(t.allocator, "{d},g{d},{d:.3},2024-{d:0>2}-{d:0>2}", .{ i, r.intRangeAtMost(u8, 0, 40), r.floatNorm(f64) * 100, r.intRangeAtMost(u8, 1, 12), r.intRangeAtMost(u8, 1, 28) });
        // Ragged and late columns must be handled identically.
        if (i % 997 == 0) try buf.appendSlice(t.allocator, ",x,late");
        try buf.appendSlice(t.allocator, "\n");
    }

    var a1 = std.heap.ArenaAllocator.init(t.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(t.allocator);
    defer a2.deinit();
    const serial = try profileString(a1.allocator(), buf.items, .{});
    const parallel = try profileString(a2.allocator(), buf.items, .{ .io = t.io, .threads = 3, .batch_rows = 1000 });

    var s1: Io.Writer.Allocating = .init(t.allocator);
    defer s1.deinit();
    var s2: Io.Writer.Allocating = .init(t.allocator);
    defer s2.deinit();
    try std.json.Stringify.value(serial, .{}, &s1.writer);
    try std.json.Stringify.value(parallel, .{}, &s2.writer);
    try t.expectEqualStrings(s1.written(), s2.written());
    try t.expectEqual(@as(usize, 6), parallel.column_count);
    try t.expect(parallel.ragged_rows > 0);
}

test "large stream switches to sketches and stays accurate" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendSlice(t.allocator, "id,bucket\n");
    const n = 100_000;
    for (0..n) |i| try buf.print(t.allocator, "{d},{d}\n", .{ i, i % 7 });
    const rep = try profileString(a.allocator(), buf.items, .{});
    const id = rep.columns[0];
    try t.expect(!id.distinct_exact);
    try t.expect(@abs(@as(f64, @floatFromInt(id.distinct)) - n) / n < 0.03);
    try t.expect(!id.numeric.?.quantiles_exact);
    try t.expectApproxEqRel(@as(f64, n / 2), id.numeric.?.p50, 0.02);
    try t.expectEqual(@as(f64, n - 1), id.numeric.?.max);
    const bucket = rep.columns[1];
    try t.expect(bucket.distinct_exact);
    try t.expectEqual(@as(u64, 7), bucket.distinct);
    try t.expect(bucket.top_exact);
}

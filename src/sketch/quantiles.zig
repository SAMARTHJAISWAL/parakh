//! `Distribution`: quantiles and a histogram for one numeric stream.
//!
//! Keeps the first `exact_limit` values verbatim and answers exactly from
//! them (numpy-style linear interpolation). Past that it frees the buffer and
//! answers from a KLL sketch fed in parallel, so small files are exact and
//! huge files cost O(k) memory.

const std = @import("std");
const Kll = @import("kll.zig").Kll;

pub const probabilities = [_]f64{ 0.05, 0.25, 0.5, 0.75, 0.95 };
pub const exact_limit = 4096;
pub const kll_k = 512;

/// Linear interpolation between closest ranks (R type 7, numpy default).
pub fn exactSorted(sorted: []const f64, p: f64) f64 {
    std.debug.assert(sorted.len > 0);
    const h = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(h));
    const hi = @min(lo + 1, sorted.len - 1);
    return sorted[lo] + (h - @floor(h)) * (sorted[hi] - sorted[lo]);
}

pub const Summary = struct {
    quantiles: [probabilities.len]f64,
    exact: bool,
};

pub const Distribution = struct {
    buffer: std.ArrayList(f64) = .empty,
    overflow: bool = false,
    sketch: Kll = .init(kll_k),

    pub fn deinit(self: *Distribution, gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
        self.sketch.deinit(gpa);
    }

    pub fn add(self: *Distribution, gpa: std.mem.Allocator, x: f64) !void {
        try self.sketch.add(gpa, x);
        if (self.overflow) return;
        if (self.buffer.items.len < exact_limit) {
            try self.buffer.append(gpa, x);
        } else {
            self.overflow = true;
            self.buffer.clearAndFree(gpa);
        }
    }

    pub fn isExact(self: *const Distribution) bool {
        return !self.overflow;
    }

    /// Quantiles at `probabilities`, plus `hist` filled with counts over
    /// equal-width buckets spanning [lo, hi]. Null when nothing was added.
    pub fn summarize(self: *Distribution, gpa: std.mem.Allocator, lo: f64, hi: f64, hist: []u64) !?Summary {
        var out: Summary = .{ .quantiles = undefined, .exact = !self.overflow };
        if (!self.overflow) {
            const v = self.buffer.items;
            if (v.len == 0) return null;
            std.mem.sortUnstable(f64, v, {}, std.sort.asc(f64));
            for (&out.quantiles, probabilities) |*o, p| o.* = exactSorted(v, p);
            @memset(hist, 0);
            const width = hi - lo;
            const last: f64 = @floatFromInt(hist.len - 1);
            for (v) |x| {
                var idx: usize = 0;
                if (width > 0) {
                    const f = (x - lo) / width * @as(f64, @floatFromInt(hist.len));
                    idx = @intFromFloat(std.math.clamp(@floor(f), 0, last));
                }
                hist[idx] += 1;
            }
            return out;
        }
        const view = try self.sketch.sortedView(gpa);
        defer gpa.free(view);
        for (&out.quantiles, probabilities) |*o, p| o.* = Kll.quantileFromView(view, p).?;
        Kll.bucketsFromView(view, lo, hi, hist);
        return out;
    }
};

const t = std.testing;

test "exactSorted matches numpy linear interpolation" {
    const v = [_]f64{ 1, 2, 3, 4 };
    try t.expectEqual(@as(f64, 2.5), exactSorted(&v, 0.5));
    try t.expectEqual(@as(f64, 1.75), exactSorted(&v, 0.25));
    try t.expectEqual(@as(f64, 4), exactSorted(&v, 1.0));
}

test "exact below the limit, sketched above it" {
    const gpa = t.allocator;
    var d: Distribution = .{};
    defer d.deinit(gpa);
    var hist: [10]u64 = undefined;
    for (0..100) |i| try d.add(gpa, @floatFromInt(i));
    const small = (try d.summarize(gpa, 0, 99, &hist)).?;
    try t.expect(small.exact);
    try t.expectEqual(@as(f64, 49.5), small.quantiles[2]);
    for (hist) |b| try t.expectEqual(@as(u64, 10), b);

    for (100..100_000) |i| try d.add(gpa, @floatFromInt(i));
    const big = (try d.summarize(gpa, 0, 99_999, &hist)).?;
    try t.expect(!big.exact);
    try t.expectApproxEqRel(@as(f64, 50_000), big.quantiles[2], 0.02);
    try t.expectApproxEqRel(@as(f64, 95_000), big.quantiles[4], 0.02);
    var total: u64 = 0;
    for (hist) |b| total += b;
    try t.expectEqual(@as(u64, 100_000), total);
}

test "empty distribution" {
    var d: Distribution = .{};
    defer d.deinit(t.allocator);
    var hist: [4]u64 = undefined;
    try t.expect((try d.summarize(t.allocator, 0, 1, &hist)) == null);
}

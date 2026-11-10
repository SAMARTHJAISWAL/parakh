//! KLL quantile sketch (Karnin, Lang & Liberty, "Optimal Quantile
//! Approximation in Streams", FOCS 2016).
//!
//! A stack of compactors. Level h holds items that each stand for 2^h
//! originals. When a level fills up it is sorted and every other item
//! (random offset) is promoted to the level above, halving its size while
//! keeping ranks unbiased. Capacities shrink geometrically (factor 2/3) toward
//! the bottom levels, so total memory is O(k) and the rank error is roughly
//! 1.7 / k regardless of stream length.
//!
//! Level 0 is unsorted and sorted only when it compacts; every higher level
//! is kept sorted by merging in the (already sorted) promoted items, so
//! compaction never re-sorts a level.
//!
//! Unlike interpolating estimators it only ever returns values that were
//! actually seen, so integer and heavily tied columns get sensible answers.

const std = @import("std");

pub const Kll = struct {
    k: u32,
    levels: std.ArrayList(std.ArrayList(f64)) = .empty,
    count: u64 = 0,
    size: usize = 0,
    max_size: usize = 0,
    prng: std.Random.DefaultPrng,
    scratch: std.ArrayList(f64) = .empty,

    pub fn init(k: u32) Kll {
        std.debug.assert(k >= 8);
        // Fixed seed: the same input always produces the same report.
        return .{ .k = k, .prng = .init(0x5EED_1A11) };
    }

    pub fn deinit(self: *Kll, gpa: std.mem.Allocator) void {
        for (self.levels.items) |*l| l.deinit(gpa);
        self.levels.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    fn capacity(self: *const Kll, h: usize) usize {
        const depth = self.levels.items.len - h - 1;
        const c = std.math.pow(f64, 2.0 / 3.0, @floatFromInt(depth)) * @as(f64, @floatFromInt(self.k));
        const geometric = @as(usize, @intFromFloat(@ceil(c))) + 1;
        // Level 0 doubles as an input buffer: compacting it rarely and in
        // big batches is much cheaper, and retaining more only helps accuracy.
        return if (h == 0) @max(geometric, self.k) else @max(geometric, 8);
    }

    fn grow(self: *Kll, gpa: std.mem.Allocator) !void {
        try self.levels.append(gpa, .empty);
        self.max_size = 0;
        for (0..self.levels.items.len) |h| self.max_size += self.capacity(h);
    }

    pub fn add(self: *Kll, gpa: std.mem.Allocator, x: f64) !void {
        if (self.levels.items.len == 0) try self.grow(gpa);
        try self.levels.items[0].append(gpa, x);
        self.count += 1;
        self.size += 1;
        if (self.size >= self.max_size) try self.compress(gpa);
    }

    fn compress(self: *Kll, gpa: std.mem.Allocator) !void {
        var h: usize = 0;
        while (h < self.levels.items.len) : (h += 1) {
            if (self.levels.items[h].items.len < self.capacity(h)) continue;
            if (h + 1 >= self.levels.items.len) try self.grow(gpa);
            // `grow` may reallocate `levels`, so take pointers afterwards.
            const level = &self.levels.items[h];
            const above = &self.levels.items[h + 1];
            if (h == 0) std.mem.sortUnstable(f64, level.items, {}, std.sort.asc(f64));
            const offset: usize = self.prng.random().int(u1);
            const pairs = level.items.len / 2;

            // Merge every other item (sorted) into the sorted level above.
            self.scratch.clearRetainingCapacity();
            try self.scratch.ensureTotalCapacity(gpa, above.items.len + pairs);
            var a: usize = 0;
            var i: usize = offset;
            while (i < pairs * 2) : (i += 2) {
                const v = level.items[i];
                while (a < above.items.len and above.items[a] <= v) : (a += 1) {
                    self.scratch.appendAssumeCapacity(above.items[a]);
                }
                self.scratch.appendAssumeCapacity(v);
            }
            self.scratch.appendSliceAssumeCapacity(above.items[a..]);
            above.clearRetainingCapacity();
            try above.appendSlice(gpa, self.scratch.items);

            // An odd item out stays behind; a single item is trivially sorted.
            const leftover: ?f64 = if (level.items.len % 2 == 1) level.items[level.items.len - 1] else null;
            level.clearRetainingCapacity();
            if (leftover) |v| level.appendAssumeCapacity(v);

            self.size = 0;
            for (self.levels.items) |l| self.size += l.items.len;
            if (self.size < self.max_size) break;
        }
    }

    pub const Weighted = struct { value: f64, weight: u64 };

    /// All retained items with their weights, sorted by value. Caller frees.
    pub fn sortedView(self: *const Kll, gpa: std.mem.Allocator) ![]Weighted {
        var out: std.ArrayList(Weighted) = .empty;
        errdefer out.deinit(gpa);
        for (self.levels.items, 0..) |l, h| {
            for (l.items) |v| try out.append(gpa, .{ .value = v, .weight = @as(u64, 1) << @intCast(h) });
        }
        std.mem.sortUnstable(Weighted, out.items, {}, struct {
            fn lt(_: void, a: Weighted, b: Weighted) bool {
                return a.value < b.value;
            }
        }.lt);
        return out.toOwnedSlice(gpa);
    }

    /// Value whose normalised rank is closest to `p` from below.
    pub fn quantileFromView(view: []const Weighted, p: f64) ?f64 {
        if (view.len == 0) return null;
        var total: u64 = 0;
        for (view) |w| total += w.weight;
        const target = p * @as(f64, @floatFromInt(total));
        var cum: u64 = 0;
        for (view) |w| {
            cum += w.weight;
            if (@as(f64, @floatFromInt(cum)) >= target) return w.value;
        }
        return view[view.len - 1].value;
    }

    /// Weighted counts in `out.len` equal-width buckets over [lo, hi].
    pub fn bucketsFromView(view: []const Weighted, lo: f64, hi: f64, out: []u64) void {
        @memset(out, 0);
        if (out.len == 0) return;
        const width = hi - lo;
        const last: f64 = @floatFromInt(out.len - 1);
        for (view) |w| {
            var idx: usize = 0;
            if (width > 0) {
                const f = (w.value - lo) / width * @as(f64, @floatFromInt(out.len));
                idx = @intFromFloat(std.math.clamp(@floor(f), 0, last));
            }
            out[idx] += w.weight;
        }
    }

    pub fn retained(self: *const Kll) usize {
        return self.size;
    }
};

const t = std.testing;

fn rankError(view: []const Kll.Weighted, sorted_truth: []const f64, p: f64) f64 {
    const q = Kll.quantileFromView(view, p).?;
    const rank = std.sort.lowerBound(f64, sorted_truth, q, struct {
        fn cmp(ctx: f64, item: f64) std.math.Order {
            return std.math.order(ctx, item);
        }
    }.cmp);
    return @abs(@as(f64, @floatFromInt(rank)) / @as(f64, @floatFromInt(sorted_truth.len)) - p);
}

test "rank error stays small on a shuffled stream, memory stays bounded" {
    const gpa = t.allocator;
    var s = Kll.init(256);
    defer s.deinit(gpa);
    const n = 200_000;
    const data = try gpa.alloc(f64, n);
    defer gpa.free(data);
    var prng = std.Random.DefaultPrng.init(99);
    for (data) |*d| d.* = prng.random().floatNorm(f64) * 10 + 50;
    for (data) |d| try s.add(gpa, d);
    try t.expect(s.retained() < 4 * 256);

    std.mem.sortUnstable(f64, data, {}, std.sort.asc(f64));
    const view = try s.sortedView(gpa);
    defer gpa.free(view);
    var total: u64 = 0;
    for (view) |w| total += w.weight;
    try t.expectEqual(@as(u64, n), total);
    for ([_]f64{ 0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99 }) |p| {
        try t.expect(rankError(view, data, p) < 0.02);
    }
}

test "sorted (adversarial) input" {
    const gpa = t.allocator;
    var s = Kll.init(200);
    defer s.deinit(gpa);
    for (0..100_000) |i| try s.add(gpa, @floatFromInt(i));
    const view = try s.sortedView(gpa);
    defer gpa.free(view);
    try t.expectApproxEqAbs(@as(f64, 50_000), Kll.quantileFromView(view, 0.5).?, 2_000);
}

test "heavy ties return a real value" {
    const gpa = t.allocator;
    var s = Kll.init(64);
    defer s.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(5);
    // 60% ones, 40% twos: the median must be exactly 1.
    for (0..50_000) |_| try s.add(gpa, if (prng.random().float(f64) < 0.6) 1 else 2);
    const view = try s.sortedView(gpa);
    defer gpa.free(view);
    try t.expectEqual(@as(f64, 1), Kll.quantileFromView(view, 0.5).?);
    try t.expectEqual(@as(f64, 2), Kll.quantileFromView(view, 0.95).?);
}

test "buckets conserve weight" {
    const gpa = t.allocator;
    var s = Kll.init(64);
    defer s.deinit(gpa);
    for (0..10_000) |i| try s.add(gpa, @floatFromInt(i % 100));
    const view = try s.sortedView(gpa);
    defer gpa.free(view);
    var out: [10]u64 = undefined;
    Kll.bucketsFromView(view, 0, 99, &out);
    var total: u64 = 0;
    for (out) |b| total += b;
    try t.expectEqual(@as(u64, 10_000), total);
    for (out) |b| try t.expect(b > 700 and b < 1300); // roughly uniform
}

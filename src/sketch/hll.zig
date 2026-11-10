//! HyperLogLog cardinality estimator (Flajolet, Fusy, Gandouet, Meunier 2007)
//! with the linear-counting correction for small ranges (Heule et al. 2013).
//!
//! 2^p one-byte registers. parakh uses p = 16: 64 KiB per column and a
//! standard error of 1.04 / sqrt(2^16) ≈ 0.41 %.

const std = @import("std");

pub fn HyperLogLog(comptime p: u6) type {
    comptime std.debug.assert(p >= 4 and p <= 18);
    return struct {
        const Self = @This();
        pub const register_count: usize = 1 << p;

        registers: [register_count]u8 = @splat(0),

        /// Add a 64-bit hash. The caller hashes; the sketch never sees raw bytes.
        pub fn addHash(self: *Self, h: u64) void {
            const idx: usize = @intCast(h >> (64 - @as(u7, p)));
            // Shift the index bits out and plant a sentinel bit so the rank is
            // bounded by 64 - p + 1 even when the remaining bits are all zero.
            const w = (h << p) | (@as(u64, 1) << (p - 1));
            const rank: u8 = @intCast(@clz(w) + 1);
            if (rank > self.registers[idx]) self.registers[idx] = rank;
        }

        pub fn estimate(self: *const Self) f64 {
            const m: f64 = @floatFromInt(register_count);
            const alpha = 0.7213 / (1.0 + 1.079 / m);
            var sum: f64 = 0;
            var zeros: usize = 0;
            for (self.registers) |r| {
                sum += std.math.ldexp(@as(f64, 1.0), -@as(i32, r));
                if (r == 0) zeros += 1;
            }
            const raw = alpha * m * m / sum;
            if (raw <= 2.5 * m and zeros > 0) {
                // Linear counting is far more accurate while registers are sparse.
                return m * @log(m / @as(f64, @floatFromInt(zeros)));
            }
            return raw;
        }

        pub fn merge(self: *Self, other: *const Self) void {
            for (&self.registers, other.registers) |*a, b| a.* = @max(a.*, b);
        }
    };
}

fn hashOf(i: u64) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&i));
}

test "empty sketch estimates zero" {
    var h: HyperLogLog(14) = .{};
    try std.testing.expectEqual(@as(f64, 0), h.estimate());
}

test "duplicates do not inflate the estimate" {
    var h: HyperLogLog(14) = .{};
    for (0..100_000) |i| h.addHash(hashOf(i % 10));
    try std.testing.expectApproxEqAbs(@as(f64, 10), h.estimate(), 0.5);
}

test "estimate within 3 standard errors across magnitudes" {
    inline for (.{ 1_000, 50_000, 1_000_000 }) |n| {
        var h: HyperLogLog(14) = .{};
        for (0..n) |i| h.addHash(hashOf(i));
        const est = h.estimate();
        const rel = @abs(est - @as(f64, n)) / @as(f64, n);
        try std.testing.expect(rel < 3 * 0.0081);
    }
}

test "merge equals union" {
    var a: HyperLogLog(12) = .{};
    var b: HyperLogLog(12) = .{};
    for (0..20_000) |i| a.addHash(hashOf(i));
    for (10_000..30_000) |i| b.addHash(hashOf(i));
    a.merge(&b);
    const rel = @abs(a.estimate() - 30_000) / 30_000;
    try std.testing.expect(rel < 0.05);
}

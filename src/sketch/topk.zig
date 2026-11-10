//! Heavy hitters: the Misra-Gries summary (Misra & Gries 1982) with the
//! amortised "purge by median" step used by Apache DataSketches'
//! frequent-items sketch.
//!
//! When all `capacity` counters are taken and an unseen value arrives, every
//! counter is reduced by the median count and those that reach zero are
//! dropped, freeing about half the slots at once. Eviction therefore costs
//! O(1) amortised instead of O(capacity) per miss.
//!
//! Guarantees: any value whose true frequency exceeds `errorBound()` is
//! present, and every stored count is within `errorBound()` below the truth.
//! While nothing has been purged the counts are exact.
//!
//! Keys live in fixed slots, so steady-state operation never allocates.

const std = @import("std");

pub const max_key_len = 96;

pub const Entry = struct {
    value: []const u8,
    count: u64,
};

pub const TopK = struct {
    capacity: usize,
    /// slot storage, `capacity * max_key_len` bytes
    keys: []u8 = &.{},
    key_lens: []u8 = &.{},
    counts: []u64 = &.{},
    free: std.ArrayList(u32) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    total: u64 = 0,
    purged: u64 = 0,

    pub fn init(capacity: usize) TopK {
        std.debug.assert(capacity >= 2 and capacity <= 256);
        return .{ .capacity = capacity };
    }

    fn ensureSlots(self: *TopK, gpa: std.mem.Allocator) !void {
        if (self.keys.len != 0) return;
        self.keys = try gpa.alloc(u8, self.capacity * max_key_len);
        self.key_lens = try gpa.alloc(u8, self.capacity);
        self.counts = try gpa.alloc(u64, self.capacity);
        try self.free.ensureTotalCapacity(gpa, self.capacity);
        var i: usize = self.capacity;
        while (i > 0) {
            i -= 1;
            self.free.appendAssumeCapacity(@intCast(i));
        }
        try self.map.ensureTotalCapacity(gpa, @intCast(self.capacity));
    }

    pub fn deinit(self: *TopK, gpa: std.mem.Allocator) void {
        if (self.keys.len != 0) {
            gpa.free(self.keys);
            gpa.free(self.key_lens);
            gpa.free(self.counts);
        }
        self.free.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn isExact(self: *const TopK) bool {
        return self.purged == 0;
    }

    pub fn errorBound(self: *const TopK) u64 {
        return self.purged;
    }

    fn slotKey(self: *const TopK, slot: u32) []const u8 {
        return self.keys[slot * max_key_len ..][0..self.key_lens[slot]];
    }

    pub fn add(self: *TopK, gpa: std.mem.Allocator, raw: []const u8) !void {
        try self.ensureSlots(gpa);
        const value = raw[0..@min(raw.len, max_key_len)];
        self.total += 1;
        if (self.map.get(value)) |slot| {
            self.counts[slot] += 1;
            return;
        }
        if (self.free.items.len == 0) self.purge();
        const slot = self.free.pop().?;
        const dst = self.keys[slot * max_key_len ..][0..value.len];
        @memcpy(dst, value);
        self.key_lens[slot] = @intCast(value.len);
        self.counts[slot] = 1;
        self.map.putAssumeCapacity(dst, slot);
    }

    fn purge(self: *TopK) void {
        // Every slot is live here; reduce all by the median count.
        var tmp: [256]u64 = undefined;
        const n = self.capacity;
        @memcpy(tmp[0..n], self.counts[0..n]);
        std.mem.sortUnstable(u64, tmp[0..n], {}, std.sort.asc(u64));
        const offset = tmp[n / 2];
        self.purged += offset;

        // Rebuild the index rather than removing entries one by one: hash
        // map removals leave tombstones, and under constant churn those make
        // every lookup probe most of the table.
        self.map.clearRetainingCapacity();
        self.free.clearRetainingCapacity();
        for (0..n) |i| {
            const slot: u32 = @intCast(i);
            if (self.counts[slot] <= offset) {
                self.free.appendAssumeCapacity(slot);
            } else {
                self.counts[slot] -= offset;
                self.map.putAssumeCapacity(self.slotKey(slot), slot);
            }
        }
    }

    /// Up to `k` entries, highest count first, ties broken by value.
    /// The value slices borrow from the summary.
    pub fn top(self: *const TopK, gpa: std.mem.Allocator, k: usize) ![]Entry {
        var all: std.ArrayList(Entry) = .empty;
        defer all.deinit(gpa);
        var it = self.map.iterator();
        while (it.next()) |e| try all.append(gpa, .{ .value = e.key_ptr.*, .count = self.counts[e.value_ptr.*] });
        std.mem.sortUnstable(Entry, all.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.value, b.value);
            }
        }.lt);
        return gpa.dupe(Entry, all.items[0..@min(k, all.items.len)]);
    }
};

test "exact while under capacity" {
    const gpa = std.testing.allocator;
    var t = TopK.init(8);
    defer t.deinit(gpa);
    for ([_][]const u8{ "a", "b", "a", "c", "a", "b" }) |v| try t.add(gpa, v);
    const top = try t.top(gpa, 2);
    defer gpa.free(top);
    try std.testing.expect(t.isExact());
    try std.testing.expectEqualStrings("a", top[0].value);
    try std.testing.expectEqual(@as(u64, 3), top[0].count);
    try std.testing.expectEqualStrings("b", top[1].value);
}

test "heavy hitters survive a flood of singletons" {
    const gpa = std.testing.allocator;
    var t = TopK.init(64);
    defer t.deinit(gpa);
    var buf: [32]u8 = undefined;
    for (0..100_000) |i| {
        if (i % 4 == 0) {
            try t.add(gpa, "HOT");
        } else if (i % 10 == 1) {
            try t.add(gpa, "WARM");
        } else {
            try t.add(gpa, try std.fmt.bufPrint(&buf, "id-{d}", .{i}));
        }
    }
    const top = try t.top(gpa, 2);
    defer gpa.free(top);
    try std.testing.expect(!t.isExact());
    try std.testing.expectEqualStrings("HOT", top[0].value);
    try std.testing.expectEqualStrings("WARM", top[1].value);
    // true - bound <= stored <= true
    try std.testing.expect(top[0].count <= 25_000);
    try std.testing.expect(top[0].count + t.errorBound() >= 25_000);
    try std.testing.expect(top[1].count <= 10_000);
    try std.testing.expect(top[1].count + t.errorBound() >= 10_000);
}

test "long values are truncated consistently" {
    const gpa = std.testing.allocator;
    var t = TopK.init(4);
    defer t.deinit(gpa);
    const long: [300]u8 = @splat('x');
    try t.add(gpa, &long);
    try t.add(gpa, &long);
    const top = try t.top(gpa, 1);
    defer gpa.free(top);
    try std.testing.expectEqual(@as(u64, 2), top[0].count);
    try std.testing.expectEqual(max_key_len, top[0].value.len);
}

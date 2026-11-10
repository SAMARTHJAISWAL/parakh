//! parakh: single-pass, bounded-memory CSV profiling.
//!
//! Use it as a library:
//!
//!     var reader: std.Io.Reader = .fixed(csv_bytes);
//!     const report = try parakh.profileReader(gpa, arena, &reader, .{});
//!     try parakh.render.write(stdout, report, .json, .{});

const std = @import("std");

pub const csv = @import("csv.zig");
pub const infer = @import("infer.zig");
pub const profile = @import("profile.zig");
pub const render = @import("render.zig");
pub const input = @import("input.zig");
pub const sketch = struct {
    pub const hll = @import("sketch/hll.zig");
    pub const quantiles = @import("sketch/quantiles.zig");
    pub const topk = @import("sketch/topk.zig");
    pub const kll = @import("sketch/kll.zig");
};

pub const Options = profile.Options;
pub const Report = profile.Report;
pub const profileReader = profile.profileReader;

pub const version = "0.1.0";

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(sketch);
}

//! Input plumbing: transparently gunzip a stream when it starts with the gzip
//! magic bytes, so `parakh data.csv.gz` and `cat data.csv.gz | parakh` work.

const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

pub const Input = struct {
    window: [flate.max_window_len]u8 = undefined,
    gunzip: flate.Decompress = undefined,
    compressed: bool = false,

    /// Returns the reader to parse from: `raw` itself, or a decompressor
    /// stacked on top of it. `self` must outlive the returned reader.
    pub fn wrap(self: *Input, raw: *Io.Reader) *Io.Reader {
        const magic = raw.peek(2) catch return raw;
        if (magic[0] != 0x1f or magic[1] != 0x8b) return raw;
        self.gunzip = .init(raw, .gzip, &self.window);
        self.compressed = true;
        return &self.gunzip.reader;
    }
};

test "plain input passes through" {
    var raw: Io.Reader = .fixed("a,b\n1,2\n");
    var in: Input = .{};
    const r = in.wrap(&raw);
    try std.testing.expect(r == &raw);
    try std.testing.expect(!in.compressed);
}

test "gzip input is decompressed" {
    // gzip of "a,b\n1,2\n" (python: gzip.compress(b"a,b\n1,2\n", mtime=0))
    const gz = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x4b, 0xd4, 0x49, 0xe2, 0x32, 0xd4, 0x31, 0xe2, 0x02, 0x00, 0x7b, 0x07, 0x97, 0x0a, 0x08, 0x00, 0x00, 0x00 };
    var raw: Io.Reader = .fixed(&gz);
    var in: Input = .{};
    const r = in.wrap(&raw);
    try std.testing.expect(in.compressed);
    var out: [64]u8 = undefined;
    const n = try r.readSliceShort(&out);
    try std.testing.expectEqualStrings("a,b\n1,2\n", out[0..n]);
}

//! WebAssembly entry point for the browser demo (web/).
//!
//! The demo runs this module inside a Web Worker. Input is pulled, not
//! pushed: the reader below calls the imported `js_read`, which the worker
//! answers synchronously with `FileReaderSync` on the next slice of the
//! dropped file. A multi-gigabyte file therefore streams through the same
//! bounded-memory pipeline as the CLI and is never loaded whole.

const std = @import("std");
const Io = std.Io;
const parakh = @import("parakh");

extern "env" fn js_read(ptr: [*]u8, len: usize) usize;
extern "env" fn js_log(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        js_log(msg.ptr, msg.len);
        @trap();
    }
}.f);

const gpa = std.heap.wasm_allocator;

var report_arena: std.heap.ArenaAllocator = .init(gpa);
var report: ?parakh.Report = null;
var output: Io.Writer.Allocating = .init(gpa);

// ------------------------------------------------------------ JS-backed reader

const js_vtable: Io.Reader.VTable = .{ .stream = jsStream, .readVec = jsReadVec };

fn jsStream(_: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try w.writableSliceGreedy(1));
    const n = js_read(dest.ptr, dest.len);
    if (n == 0) return error.EndOfStream;
    w.advance(n);
    return n;
}

/// Fill the reader's own buffer directly; this is the path the CSV parser
/// and the gzip decompressor use.
fn jsReadVec(r: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
    const dest = r.buffer[r.end..];
    if (dest.len == 0) return 0;
    const n = js_read(dest.ptr, dest.len);
    if (n == 0) return error.EndOfStream;
    r.end += n;
    return 0;
}

// ------------------------------------------------------------ exports

export fn parakh_alloc(n: usize) ?[*]u8 {
    const s = gpa.alloc(u8, n) catch return null;
    return s.ptr;
}

export fn parakh_free(ptr: [*]u8, n: usize) void {
    gpa.free(ptr[0..n]);
}

/// Profile the stream behind `js_read`. `delimiter` 0 means sniff.
/// Returns 0 on success, or the length of an error message in the output.
export fn parakh_profile(source_ptr: [*]const u8, source_len: usize, has_header: bool, delimiter: u32, top_n: u32) usize {
    _ = report_arena.reset(.free_all);
    report = null;
    output.clearRetainingCapacity();
    profile(source_ptr[0..source_len], has_header, delimiter, top_n) catch |err| {
        output.writer.print("{s}", .{@errorName(err)}) catch {};
        return output.written().len;
    };
    return 0;
}

fn profile(source: []const u8, has_header: bool, delimiter: u32, top_n: u32) !void {
    const buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(buf);
    var raw: Io.Reader = .{ .vtable = &js_vtable, .buffer = buf, .seek = 0, .end = 0 };
    const in = try gpa.create(parakh.input.Input);
    defer gpa.destroy(in);
    in.* = .{};
    const reader = in.wrap(&raw);
    report = try parakh.profileReader(gpa, report_arena.allocator(), reader, .{
        .has_header = has_header,
        .delimiter = if (delimiter == 0) null else @intCast(delimiter),
        .top_n = top_n,
        .source = source,
    });
}

/// Render the last report: 0 = JSON, 1 = Markdown, 2 = plain table.
/// Returns the byte length; read it from `parakh_output_ptr`.
export fn parakh_render(format: u32) usize {
    output.clearRetainingCapacity();
    const r = report orelse return 0;
    const fmt: parakh.render.Format = switch (format) {
        0 => .json,
        1 => .markdown,
        else => .table,
    };
    parakh.render.write(&output.writer, r, fmt, .{}) catch return 0;
    return output.written().len;
}

export fn parakh_output_ptr() [*]const u8 {
    return output.written().ptr;
}

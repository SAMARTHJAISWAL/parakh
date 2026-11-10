const std = @import("std");
const Io = std.Io;
const parakh = @import("parakh");
const render = parakh.render;

const usage =
    \\parakh — profile a CSV in one pass, with bounded memory.
    \\
    \\Usage: parakh [options] [FILE]
    \\
    \\FILE may be .csv, .tsv or gzip-compressed (.gz is detected from content).
    \\With no FILE, or FILE is -, read standard input.
    \\
    \\Options:
    \\  -f, --format <fmt>     table (default), markdown, json
    \\  -d, --delimiter <c>    field delimiter: a character or 'tab' (default: sniffed)
    \\      --no-header        first row is data; columns are named column_1, column_2, ...
    \\  -n, --top <N>          top values kept per column (default 5, max 64)
    \\      --color <when>     auto (default), always, never. NO_COLOR is respected.
    \\  -j, --threads <N>      worker threads (default: cores - 1; 1 = single-threaded)
    \\      --fail-on-warn     exit with status 2 if any warning is found (for CI gates)
    \\  -h, --help             show this help
    \\  -V, --version          show version
    \\
    \\Examples:
    \\  parakh sales.csv
    \\  parakh -f json events.csv.gz | jq '.columns[] | select(.null_ratio > 0.1)'
    \\  curl -s https://example.com/data.csv | parakh -f markdown > PROFILE.md
    \\
;

const Color = enum { auto, always, never };

const Args = struct {
    path: ?[]const u8 = null,
    format: render.Format = .table,
    delimiter: ?u8 = null,
    has_header: bool = true,
    top_n: usize = 5,
    color: Color = .auto,
    fail_on_warn: bool = false,
    threads: ?usize = null,
    help: bool = false,
    version: bool = false,
};

const ArgError = error{InvalidArgument};

fn parseArgs(argv: []const []const u8, err_msg: *[]const u8) ArgError!Args {
    var a: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const takesValue = struct {
            fn f(list: []const []const u8, idx: *usize, msg: *[]const u8, name: []const u8) ArgError![]const u8 {
                idx.* += 1;
                if (idx.* >= list.len) {
                    msg.* = name;
                    return error.InvalidArgument;
                }
                return list[idx.*];
            }
        }.f;
        if (eql(arg, "-h") or eql(arg, "--help")) {
            a.help = true;
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            a.version = true;
        } else if (eql(arg, "-f") or eql(arg, "--format")) {
            const v = try takesValue(argv, &i, err_msg, arg);
            a.format = std.meta.stringToEnum(render.Format, v) orelse
                if (eql(v, "md")) .markdown else {
                    err_msg.* = "--format must be table, markdown or json";
                    return error.InvalidArgument;
                };
        } else if (eql(arg, "-d") or eql(arg, "--delimiter")) {
            const v = try takesValue(argv, &i, err_msg, arg);
            if (eql(v, "tab") or eql(v, "\\t")) {
                a.delimiter = '\t';
            } else if (v.len == 1 and v[0] != '"' and v[0] != '\n' and v[0] != '\r') {
                a.delimiter = v[0];
            } else {
                err_msg.* = "--delimiter must be a single character or 'tab'";
                return error.InvalidArgument;
            }
        } else if (eql(arg, "--no-header")) {
            a.has_header = false;
        } else if (eql(arg, "-n") or eql(arg, "--top")) {
            const v = try takesValue(argv, &i, err_msg, arg);
            a.top_n = std.fmt.parseInt(usize, v, 10) catch {
                err_msg.* = "--top must be a number";
                return error.InvalidArgument;
            };
            a.top_n = @min(a.top_n, 64);
        } else if (eql(arg, "--color") or eql(arg, "--colour")) {
            const v = try takesValue(argv, &i, err_msg, arg);
            a.color = std.meta.stringToEnum(Color, v) orelse {
                err_msg.* = "--color must be auto, always or never";
                return error.InvalidArgument;
            };
        } else if (eql(arg, "-j") or eql(arg, "--threads")) {
            const v = try takesValue(argv, &i, err_msg, arg);
            const n = std.fmt.parseInt(usize, v, 10) catch {
                err_msg.* = "--threads must be a number";
                return error.InvalidArgument;
            };
            a.threads = @max(n, 1);
        } else if (eql(arg, "--fail-on-warn")) {
            a.fail_on_warn = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            err_msg.* = arg;
            return error.InvalidArgument;
        } else {
            if (a.path != null) {
                err_msg.* = "only one FILE may be given";
                return error.InvalidArgument;
            }
            a.path = arg;
        }
    }
    return a;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &stdout_fw.interface;
    var err_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(arena);
    var err_msg: []const u8 = "";
    const args = parseArgs(argv[1..], &err_msg) catch {
        try stderr.print("parakh: invalid argument: {s}\nTry 'parakh --help'.\n", .{err_msg});
        try stderr.flush();
        return 64;
    };
    if (args.help) {
        try stdout.writeAll(usage);
        try stdout.flush();
        return 0;
    }
    if (args.version) {
        try stdout.print("parakh {s}\n", .{parakh.version});
        try stdout.flush();
        return 0;
    }

    const from_stdin = args.path == null or eql(args.path.?, "-");
    const file: Io.File = if (from_stdin) .stdin() else Io.Dir.cwd().openFile(io, args.path.?, .{}) catch |err| {
        try stderr.print("parakh: cannot open '{s}': {s}\n", .{ args.path.?, @errorName(err) });
        try stderr.flush();
        return 1;
    };
    defer if (!from_stdin) file.close(io);

    const in_buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(in_buf);
    var file_reader: Io.File.Reader = if (from_stdin) .initStreaming(file, io, in_buf) else .init(file, io, in_buf);

    // Transparent gzip: sniff the magic bytes rather than trusting the name.
    const in = try gpa.create(parakh.input.Input);
    defer gpa.destroy(in);
    in.* = .{};
    const reader = in.wrap(&file_reader.interface);

    var delimiter = args.delimiter;
    if (delimiter == null and !from_stdin and std.ascii.endsWithIgnoreCase(stripGz(args.path.?), ".tsv")) {
        delimiter = '\t';
    }

    const start = Io.Timestamp.now(io, .awake);
    const report = parakh.profileReader(gpa, arena, reader, .{
        .has_header = args.has_header,
        .delimiter = delimiter,
        .top_n = args.top_n,
        .source = if (from_stdin) "<stdin>" else std.fs.path.basename(args.path.?),
        .io = if (args.threads == 1) null else io,
        .threads = args.threads,
    }) catch |err| {
        try stderr.print("parakh: failed to read input: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return 1;
    };
    const elapsed = start.untilNow(io, .awake).toNanoseconds();

    const color = switch (args.color) {
        .always => true,
        .never => false,
        .auto => init.environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false),
    };
    try render.write(stdout, report, args.format, .{
        .color = color,
        .elapsed_ns = @intCast(@max(elapsed, 0)),
    });
    try stdout.flush();

    if (args.fail_on_warn) {
        for (report.findings) |f| if (f.severity == .warn) return 2;
    }
    return 0;
}

fn stripGz(path: []const u8) []const u8 {
    return if (std.ascii.endsWithIgnoreCase(path, ".gz")) path[0 .. path.len - 3] else path;
}

test "argument parsing" {
    var msg: []const u8 = "";
    const a = try parseArgs(&.{ "-f", "json", "-d", "tab", "--no-header", "-n", "3", "data.csv" }, &msg);
    try std.testing.expectEqual(render.Format.json, a.format);
    try std.testing.expectEqual(@as(?u8, '\t'), a.delimiter);
    try std.testing.expect(!a.has_header);
    try std.testing.expectEqual(@as(usize, 3), a.top_n);
    try std.testing.expectEqualStrings("data.csv", a.path.?);

    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{"--bogus"}, &msg));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "-f", "xml" }, &msg));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{"-d"}, &msg));
    try std.testing.expectEqual(render.Format.markdown, (try parseArgs(&.{ "-f", "md" }, &msg)).format);
}

test "stripGz" {
    try std.testing.expectEqualStrings("a.tsv", stripGz("a.tsv.gz"));
    try std.testing.expectEqualStrings("a.csv", stripGz("a.csv"));
}

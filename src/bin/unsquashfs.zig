const std = @import("std");
const config = @import("config");
const squashfs = @import("squashfs");

const help_msg =
    \\Basic Usage: zig-unsquashfs [Options] SQUASHFS_FILE <EXTRACT_LOCATION>
    \\
    \\General options:
    \\  -e <path>           Path to a file or directory inside the archive to extract instead of the whole archive.
    \\                          Can be given multiple times.
    \\  -o <bytes>          Skip <bytes> before reading from the archive.
    \\  -v                  Verbose output.
    \\
    \\Extraction options:
    \\  --unbreak-symlinks  Attempt extract symlink targets along with symlinks. Will not place files outside of the extraction location.
    \\  -us                 Same as --unbreak-symlinks
    \\  --deref-symlinks    Replace symlink files with their target.
    \\  -ds                 Same as --deref-symlinks
    \\  -p <#>              Use at most # of processors. Defaults to logical core count.
    \\
    \\Listing Options:
    \\  -l                  List files instead of extracting. When used, you do not need to specify an extraction location.
    \\  -ll                 Similiar to -l, but with file attributes.
    \\  -lln                Similiar to -ll, but with numeric uids and gids.
    \\
    \\Other:
    \\  --help              Prints this help message.
    \\  -h                  Same as --help
    \\  --version           Print version number.
    \\
;

const stdout = std.io.getStdOut();

var extr_files: std.ArrayList([]const u8) = undefined;
var offset: u64 = 0;
var verbose: bool = false;
var unbreak: bool = false;
var deref: bool = false;
var processors: u16 = 0;
var list: ListTypes = .None;

var filename: []const u8 = "";
var extr_location: []const u8 = "";

const ListTypes = enum {
    None,
    List,
    ListAttr,
    ListNumeric,
};

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    extr_files = .init(alloc);
    defer extr_files.deinit();
    var args = std.process.argsWithAllocator(alloc) catch {
        _ = try stdout.writeAll("Unable to allocate memory");
        return;
    };
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = try stdout.writeAll(help_msg);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try config.version.format("", .{}, stdout.writer());
            _ = try stdout.write("\n");
            return;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--unbreak-symlinks") or std.mem.eql(u8, arg, "-us")) {
            unbreak = true;
        } else if (std.mem.eql(u8, arg, "--deref-symlinks") or std.mem.eql(u8, arg, "-ds")) {
            deref = true;
        } else if (std.mem.eql(u8, arg, "-l")) {
            list = .List;
        } else if (std.mem.eql(u8, arg, "-ll")) {
            list = .ListAttr;
        } else if (std.mem.eql(u8, arg, "-lln")) {
            list = .ListNumeric;
        } else if (std.mem.eql(u8, arg, "-e")) {
            const next = args.next();
            if (next == null) {
                _ = try stdout.writeAll("path required after -e\n");
                return;
            }
            try extr_files.append(next.?);
        } else if (std.mem.eql(u8, arg, "-o")) {
            const next = args.next();
            if (next == null) {
                _ = try stdout.writeAll("offset required after -o\n");
                return;
            }
            offset = try std.fmt.parseInt(u64, next.?, 10);
        } else if (std.mem.eql(u8, arg, "-p")) {
            const next = args.next();
            if (next == null) {
                _ = try stdout.writeAll("number required after -p\n");
                return;
            }
            processors = try std.fmt.parseInt(u16, next.?, 10);
        } else if (filename.len == 0) {
            filename = arg;
        } else if (extr_location.len == 0) {
            extr_location = arg;
        } else {
            _ = try stdout.writeAll("invalid or too many arguments\n");
            return;
        }
    }
    if (filename.len == 0) {
        _ = try stdout.writeAll("no archive given\n");
        return;
    }
    if (list == .None and extr_location.len == 0) {
        _ = try stdout.writeAll("no extract location given\n");
        return;
    }
    const fil = try std.fs.cwd().openFile(filename, .{});
    defer fil.close();
    var th_alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = std.heap.smp_allocator };
    var rdr = squashfs.SfsFile.init(
        th_alloc.allocator(),
        fil,
        offset,
    ) catch |err| {
        try std.fmt.format(stdout.writer(), "Error opening {s} as squashfs: {any}\n", .{ filename, err });
        return;
    };
    defer rdr.deinit();
    //TODO: list and extr_files;
    var op: squashfs.ExtractionOptions = squashfs.ExtractionOptions.init() catch |err| {
        try std.fmt.format(stdout.writer(), "Error setting extraction options: {any}\n", .{err});
        return;
    };
    op.verbose = verbose;
    op.dereference_symlinks = deref;
    op.unbreak_symlinks = unbreak;
    if (processors != 0) op.thread_count = processors;
    rdr.extract(op, extr_location) catch |err| {
        try std.fmt.format(stdout.writer(), "Error extracting archive: {any}\n", .{err});
        return;
    };
}

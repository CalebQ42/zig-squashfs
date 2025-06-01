const std = @import("std");
const config = @import("config");

const File = @import("file.zig").File;
const Reader = @import("reader.zig").Reader;
const ExtractConfig = @import("file.zig").File.ExtractConfig;

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

fn help() !void {
    const help_msg =
        \\Basic Usage: zig-unsquashfs [Options] SQUASHFS_FILE EXTRACT_LOCATION
        \\
        \\General options:
        \\  -e <path>           Path to a file or directory inside the archive to extract instead of the whole archive.
        \\                          Can be given multiple times.
        \\  -o <bytes>          Skip <bytes> before reading from the archive.
        \\  -v                  Verbose output.
        \\  --help              Prints this help message.
        \\  -h                  Same as --help
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
        \\  -ll                 Like -l, but with file attributes.
        \\  -lln                Like -ll, but with numeric uids and gids.
        \\
        \\Other:
        \\  --version           Print version number.
        \\
    ;
    _ = try stdout.writeAll(help_msg);
}

pub fn main() !void {
    var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
    extr_files = .init(alloc.allocator());
    defer extr_files.deinit();
    var args = std.process.argsWithAllocator(alloc.allocator()) catch {
        _ = try stdout.writeAll("Unable allocate memory");
        return;
    };
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try help();
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
        } else if (std.mem.eql(u8, arg, "--version")) {
            try config.version.format("", .{}, stdout.writer());
            _ = try stdout.write("\n");
            return;
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
    var rdr = Reader.init(
        alloc.allocator(),
        filename,
        offset,
    ) catch |err| {
        try std.fmt.format(stdout.writer(), "Error opening {s} as squashfs: {any}\n", .{ filename, err });
        return;
    };
    defer rdr.deinit();
    switch (list) {
        .None => {
            var conf = ExtractConfig.init() catch |err| {
                try std.fmt.format(stdout.writer(), "Error getting system info: {any}\n", .{err});
                return;
            };
            conf.deref_sym = deref;
            conf.unbreak_sym = unbreak;
            conf.verbose = verbose;
            if (extr_files.items.len == 0) {
                rdr.root.extract(&rdr, conf, extr_location) catch |err| {
                    try std.fmt.format(stdout.writer(), "Error extracting archive: {any}\n", .{err});
                    return;
                };
            } else {
                for (extr_files.items) |path| {
                    var fil = rdr.root.open(&rdr, path) catch |err| {
                        try std.fmt.format(stdout.writer(), "Error extracting {s}: {any}\n", .{ path, err });
                        return;
                    };
                    defer fil.deinit(alloc.allocator());
                    fil.extract(&rdr, conf, extr_location) catch |err| {
                        try std.fmt.format(stdout.writer(), "Error extracting {s}: {any}\n", .{ path, err });
                        return;
                    };
                }
            }
        },
        else => {
            if (extr_files.items.len == 0) {
                try printFile(alloc.allocator(), &rdr, &rdr.root);
            } else {
                for (extr_files.items) |path| {
                    var fil = rdr.root.open(&rdr, path) catch |err| {
                        try std.fmt.format(stdout.writer(), "Error finding {s}: {any}\n", .{ path, err });
                        return;
                    };
                    defer fil.deinit(alloc.allocator());
                    try printFile(alloc.allocator(), &rdr, &fil);
                }
            }
        },
    }
}

fn printFile(alloc: std.mem.Allocator, rdr: *Reader, f: *File) anyerror!void {
    const pth = try f.file_path(alloc);
    defer alloc.free(pth);
    if (list == .List) {
        try std.fmt.format(stdout.writer(), "{s}\n", .{pth});
        if (f.isDir()) {
            try printDir(alloc, rdr, f);
        }
        return;
    }
    try std.fmt.format(stdout.writer(), "{s} {d}/{d} {d} {s}\n", .{ "tmp-perm", try f.uid(rdr), try f.gid(rdr), f.size(), pth });
    if (f.isDir()) {
        try printDir(alloc, rdr, f);
    }
}

fn printDir(alloc: std.mem.Allocator, rdr: *Reader, f: *File) anyerror!void {
    var iter = try f.iterator(rdr);
    defer iter.deinit();
    while (iter.next()) |fil| {
        try printFile(alloc, rdr, fil);
    }
}

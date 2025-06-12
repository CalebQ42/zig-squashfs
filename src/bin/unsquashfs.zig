const std = @import("std");
const config = @import("config");
const sfs = @import("squashfs");

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
}

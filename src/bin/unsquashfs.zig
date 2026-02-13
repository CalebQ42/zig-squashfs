const std = @import("std");
const Writer = std.Io.Writer;
const builtin = @import("builtin");

const config = @import("config");
const squashfs = @import("zig_squashfs");

//TODO: Add more options
const help_mgs =
    \\
    \\Usage: unsquashfs [options] <archive>
    \\
    \\Options:
    \\  -d <location>   Extract to the given location instead of "squashfs-root"
    \\
    \\  -o <offset>     Start reading the archive at the given offset.
    \\
    \\  -p <threads>    Specify how many threads to use. If no present or zero, the system's logical cores count is used.
    \\  -v              Verbose
    \\
    \\  --help          Display this messages
    \\  --version       Display the version
    \\
;

const errors = error{InvalidArguments};

var archive: []const u8 = "";
var extLoc: []const u8 = "squashfs-root";
var offset: u64 = 0;
var threads: u32 = 0;
var verbose: bool = false;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var stdout = std.fs.File.stdout();
    var out = stdout.writer(&[0]u8{});
    defer out.interface.flush() catch {};
    try handleArgs(alloc, &out.interface);
    if (archive.len == 0) {
        try out.interface.print("You must provide a squashfs archive\n", .{});
        try out.interface.print(help_mgs, .{});
        return;
    }
    var fil: std.fs.File = try std.fs.cwd().openFile(archive, .{}); //TODO: Handle error gracefully.
    defer fil.close();
    var arc: squashfs.Archive = try .initAdvanced(alloc, fil, offset, threads); //TODO: Update when memory size matters. //TODO: Handle error gracefully.
    defer arc.deinit();
    try arc.extract(extLoc, if (verbose) .VerboseDefault(&out.interface) else .Default); //TODO: Handle error gracefully.
}

fn handleArgs(alloc: std.mem.Allocator, out: *Writer) !void {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // args[0] is the application launch command.
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            const nxt = args.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-o must be followed by a number\n", .{});
                return errors.InvalidArguments;
            }
            offset = std.fmt.parseInt(u64, nxt.?, 10) catch {
                try out.print("-o must be followed by a number\n", .{});
                return errors.InvalidArguments;
            };
            continue;
        } else if (std.mem.eql(u8, arg, "-d")) {
            const nxt = args.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-d must be followed by a location\n", .{});
                return errors.InvalidArguments;
            }
            extLoc = nxt.?;
            continue;
        } else if (std.mem.eql(u8, arg, "-p")) {
            const nxt = args.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-p must be followed by a number\n", .{});
                return errors.InvalidArguments;
            }
            threads = std.fmt.parseInt(u32, nxt.?, 10) catch {
                try out.print("-p must be followed by a number\n", .{});
                return errors.InvalidArguments;
            };
            continue;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try out.print("zig-unsquashfs v", .{});
            try config.version.format(out);
            try out.print("\nBuilt using Zig {s} in {} mode\n", .{ builtin.zig_version_string, builtin.mode });
            std.process.exit(0);
            return;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try out.print(help_mgs, .{});
            std.process.exit(0);
            return;
        }
        if (archive.len > 0) {
            try out.print("you can only provide one file at a time\n", .{});
            try out.print(help_mgs, .{});
            return errors.InvalidArguments;
        }
        archive = arg;
    }
}

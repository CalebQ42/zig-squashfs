const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
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
    \\  -dx             Don't set xattr values
    \\  -dp             Don't set permissions (includes setting uid & gid owner)
    \\
    \\  -p <threads>    Specify how many threads to use. If no present or zero, the system's logical cores count is used.
    \\  -v              Verbose
    \\
    \\  --force         Force extraction. If the destination already exists, it will be deleted.
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
var ignore_xattrs: bool = false;
var ignore_permissions: bool = false;
var force: bool = false;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var stdout = std.Io.File.stdout();
    var out = stdout.writer(io, &[0]u8{});
    defer out.interface.flush() catch {};
    try handleArgs(init.minimal.args, &out.interface);
    if (archive.len == 0) {
        try out.interface.print("You must provide a squashfs archive\n", .{});
        try out.interface.print(help_mgs, .{});
        return;
    }
    var fil: Io.File = try Io.Dir.cwd().openFile(io, archive, .{}); //TODO: Handle error gracefully.
    defer fil.close(io);
    var arc: squashfs.Archive = try .init(io, fil, offset); //TODO: Handle error gracefully.
    const options: squashfs.ExtractionOptions = .{
        .threads = if (threads == 0) try std.Thread.getCpuCount() else threads,
        .verbose = verbose,
        .verbose_writer = if (verbose) &out.interface else null,
        .ignore_xattr = ignore_xattrs,
        .ignore_permissions = ignore_permissions,
    };
    if (force)
        try Io.Dir.cwd().deleteTree(io, extLoc);
    try arc.extract(alloc, extLoc, options); //TODO: Handle error gracefully.
}

fn handleArgs(args: std.process.Args, out: *Writer) !void {
    var arg_iter = args.iterate();
    defer arg_iter.deinit();
    _ = arg_iter.next(); // args[0] is the application launch command.
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            const nxt = arg_iter.next();
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
            const nxt = arg_iter.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-d must be followed by a location\n", .{});
                return errors.InvalidArguments;
            }
            extLoc = nxt.?;
            continue;
        } else if (std.mem.eql(u8, arg, "-p")) {
            const nxt = arg_iter.next();
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
        } else if (std.mem.eql(u8, arg, "-dx")) {
            ignore_xattrs = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-dp")) {
            ignore_permissions = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
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

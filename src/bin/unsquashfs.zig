const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const builtin = @import("builtin");

const build = @import("build");
const squashfs = @import("squashfs");

//TODO: Add more options
const help_mgs =
    \\
    \\Usage: unsquashfs [options] <archive>
    \\
    \\Options:
    \\  -d <location>   Extract to the given location instead of "squashfs-root"
    \\  -f <filepath>   Extract the files at the given filepath instead of the entire archive
    \\                     Can be given multiple times.
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
var ext_loc: []const u8 = "squashfs-root";
var offset: u64 = 0;
var threads: u32 = 0;
var verbose: bool = false;
var ignore_xattrs: bool = false;
var ignore_permissions: bool = false;
var force: bool = false;
var files: [][:0]const u8 = &[0][:0]const u8{};

var limited: ?Io.Threaded = null;

pub fn main(init: std.process.Init) !void {
    var io = init.io;
    const alloc = init.gpa;

    var stdout = Io.File.stdout();
    var out = stdout.writer(io, &[0]u8{});
    defer out.interface.flush() catch {};

    try handleArgs(alloc, init.minimal.args, &out.interface);
    if (archive.len == 0) {
        try out.interface.print("You must provide a squashfs archive\n", .{});
        try out.interface.print(help_mgs, .{});
        return;
    }

    var fil = try Io.Dir.cwd().openFile(io, archive, .{}); //TODO: Handle error gracefully.
    defer fil.close(io);

    var arc: squashfs.Archive = try .init(io, fil, offset); //TODO: Update when memory size matters. //TODO: Handle error gracefully.
    defer arc.deinit(io);
    const options: squashfs.ExtractionOptions = .{
        .single_threaded = (threads == 1),
        .verbose = verbose,
        .verbose_writer = if (verbose) &out.interface else null,
        .ignore_xattr = ignore_xattrs,
        .ignore_permissions = ignore_permissions,
    };

    if (threads > 1) {
        limited = Io.Threaded.init(alloc, .{
            .argv0 = .init(init.minimal.args),
            .async_limit = @enumFromInt(threads),
            .concurrent_limit = @enumFromInt(threads),
            .environ = init.minimal.environ,
        });
        io = limited.?.io();
    }

    if (force)
        try Io.Dir.cwd().deleteTree(io, ext_loc);

    if (files.len > 0) {
        for (0..files.len) |i| {
            var sfs_fil = try arc.open(alloc, files[i]);
            defer sfs_fil.deinit();

            const last_ind = std.mem.lastIndexOf(u8, files[i], "/");
            const file_name = if (last_ind != null) files[i][last_ind.?..] else files[i];

            const fil_ext_loc = if (ext_loc.len > 0)
                try std.mem.concat(alloc, u8, &.{ ext_loc, "/", file_name })
            else
                file_name;

            defer if (fil_ext_loc.len != file_name.len) alloc.free(fil_ext_loc);

            try sfs_fil.extract(alloc, io, fil_ext_loc, options);
        }
    } else {
        try arc.extract(alloc, io, ext_loc, options); //TODO: Handle error gracefully.
    }
}

fn handleArgs(alloc: std.mem.Allocator, main_args: std.process.Args, out: *Writer) !void {
    var args = main_args.iterate();
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
        } else if (std.mem.eql(u8, arg, "-f")) {
            const nxt = args.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-d must be followed by a location\n", .{});
                return errors.InvalidArguments;
            }
            if (!alloc.resize(files, files.len + 1)) {
                const new_alloc = try alloc.alloc([:0]const u8, files.len + 1);
                @memcpy(new_alloc[0..files.len], files);
                alloc.free(files);
                files = new_alloc;
            } else {
                files.len += 1;
            }
            files[files.len - 1] = nxt.?;
            continue;
        } else if (std.mem.eql(u8, arg, "-d")) {
            const nxt = args.next();
            if (nxt == null or nxt.?.len == 0) {
                try out.print("-d must be followed by a location\n", .{});
                return errors.InvalidArguments;
            }
            ext_loc = std.mem.trim(u8, nxt.?, "/");
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
            try build.version.format(out);
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

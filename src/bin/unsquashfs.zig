const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Writer = Io.Writer;

const config = @import("build_config");
const squashfs = @import("squashfs");
const Archive = squashfs.Archive;
const Options = squashfs.Options;

//TODO: Add more options
const help_msg =
    \\
    \\Usage: unsquashfs [options] <archive>
    \\
    \\Options:
    \\  -d <location>   Extract to the given location instead of "squashfs-root"
    \\
    \\  -o <offset>     Start reading the archive at the given offset (in bytes).
    \\  -ix             Ignore xattr values
    \\  -ip             Ignore permissions (includes setting uid & gid)
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

var arc_loc: [:0]const u8 = "";
var ext_loc: [:0]const u8 = "squashfs-root";

var offset: u64 = 0;
var threads: usize = 0;
var force: bool = false;

var options: Options = .default;

pub fn main(init: std.process.Init) !void {
    var io = init.io;
    const alloc = init.gpa;

    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &[0]u8{});
    defer stdout.flush() catch {};

    try processArgs(init.minimal.args, &stdout.interface);

    var limited_io: Io.Threaded = undefined;
    if (threads != 0) {
        if (threads == 1) {
            limited_io = Io.Threaded.init_single_threaded;
            options.single_threaded = true;
        } else {
            limited_io = Io.Threaded.init(alloc, .{
                .async_limit = .limited(threads),
                .concurrent_limit = .limited(threads),
                .argv0 = .init(init.minimal.args),
                .environ = init.minimal.environ,
            });
        }
        io = limited_io.io();
    }

    var fil = try Io.Dir.cwd().openFile(io, arc_loc, .{});
    defer fil.close(io);

    var arc: Archive = try .init(io, fil, offset);
    defer arc.deinit(io);

    try arc.extract(alloc, io, ext_loc, options);
}

fn processArgs(args: std.process.Args, stdout: *Io.Writer) !void {
    var iter = args.iterate();

    _ = iter.next();

    while (iter.next()) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] != '-') {
            if (arc_loc.len == 0) {
                arc_loc = arg;
            } else {
                try stdout.print("Invalid argument: {s}\n", .{arg});
                return error.InvalidArgument;
            }
            continue;
        }

        var flag = arg[1..];
        if (flag.len == 0) {
            try stdout.print("Invalid argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
        if (flag[0] == '-') {
            flag = flag[1..];
            if (flag.len == 0) {
                try stdout.print("Invalid argument: {s}\n", .{arg});
                return error.InvalidArgument;
            }
            if (std.mem.eql(u8, flag, "force")) {
                force = true;
            } else if (std.mem.eql(u8, flag, "help")) {
                try stdout.print(help_msg, .{});
            } else if (std.mem.eql(u8, flag, "version")) {
                try stdout.print("v{} built with zig {}\n", .{ config.version, builtin.zig_version });
            } else {
                try stdout.print("Invalid argument: {s}\n", .{arg});
                return error.InvalidArgument;
            }
            continue;
        }

        if (flag.len >= 3) {
            try stdout.print("Invalid argument: {s}\n", .{arg});
            return error.InvalidArgument;
        } else if (flag.len == 2 and flag[0] != 'i') {
            try stdout.print("Invalid argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
        switch (flag[0]) {
            'd' => ext_loc = iter.next() orelse {
                try stdout.print("bad argument: -d must be followed by a location\n", .{});
                return error.InvalidArgument;
            },
            'o' => {
                const offset_raw = iter.next() orelse {
                    try stdout.print("bad argument: -o must be followed by a byte offset\n", .{});
                    return error.InvalidArgument;
                };
                offset = try std.fmt.parseInt(u64, offset_raw, 10);
            },
            'i' => switch (flag[1]) {
                'x' => options.ignore_xattr = true,
                'p' => options.ignore_permissions = true,
                else => {
                    try stdout.print("Invalid argument: {s}\n", .{arg});
                    return error.InvalidArgument;
                },
            },
            'p' => {
                const threads_raw = iter.next() orelse {
                    try stdout.print("bad argument: -p must be followed by the number of threads\n", .{});
                    return error.InvalidArgument;
                };
                threads = try std.fmt.parseInt(u64, threads_raw, 10);
            },
            'v' => {
                options.verbose = true;
                options.verbose_writer = stdout;
            },
            else => {
                try stdout.print("Invalid argument: {s}\n", .{arg});
                return error.InvalidArgument;
            },
        }
    }
}

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;

const config = @import("build_config");
const squashfs = @import("squashfs");
const Archive = squashfs.Archive;
const Options = squashfs.Options;

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

var arc_loc: []const u8 = "";
var ext_loc: []const u8 = "squashfs-root";

var offset: u64 = 0;
var threads: usize = 0;
var force: bool = false;

var options: Options = .default;

pub fn main(init: std.process.Init) !void {
    var io = init.io;
    const alloc = init.gpa;

    // TODO: process args

    var limited_io: Io.Threaded = undefined;
    if (threads != 0) {
        limited_io = if (threads == 1)
            Io.Threaded.init_single_threaded
        else
            Io.Threaded.init(alloc, .{
                .async_limit = .limited(threads),
                .concurrent_limit = .limited(threads),
                .argv0 = .init(init.minimal.args),
                .environ = init.minimal.environ,
            });
        io = limited_io.io();
    }

    var fil = try Io.Dir.cwd().openFile(io, arc_loc, .{});
    defer fil.close(io);

    var arc: Archive = try .open(io, fil, offset);
    defer arc.close(io);

    try arc.extract(alloc, io, ext_loc, options);
}

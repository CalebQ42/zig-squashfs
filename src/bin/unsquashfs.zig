const std = @import("std");
const Writer = std.Io.Writer;

const squashfs = @import("zig_squashfs");

//TODO: Add more options
const help_mgs =
    \\Usage: unsquashfs [options] <archive>
    \\
    \\Options:
    \\  -o <offset>     Start reading the archive at the given offset.
    \\  -d <location>   Extract to the given location instead of "squashfs-root"
;

const errors = error{InvalidArguments};

var archive: []const u8 = "";
var extLoc: []const u8 = "squashfs-root";
var offset: u64 = 0;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var stdout = std.fs.File.stdout();
    var out = stdout.writer(&[0]u8{});
    defer out.interface.flush() catch {};
    try handleArgs(alloc, &out.interface);
    var fil: std.fs.File = try std.fs.cwd().openFile(archive, .{}); //TODO: Handle error gracefully.
    defer fil.close();
    var arc: squashfs.Archive = try .initAdvanced(alloc, fil, offset, try std.Thread.getCpuCount(), 0); //TODO: Update when memory size matters. //TODO: Handle error gracefully.
    defer arc.deinit();
    try arc.extract(extLoc, .Default); //TODO: Handle error gracefully.
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
        }
        if (archive.len > 0) {
            try out.print("you can only provide one file at a time\n", .{});
            return errors.InvalidArguments;
        }
        archive = arg;
    }
}

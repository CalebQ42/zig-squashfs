const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Zlib = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue(c.z_stream),

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Zlib {
    return .{
        .alloc = alloc,

        .queue = try .init(alloc, try std.Thread.getCpuCount()),
    };
}
pub fn deinit(self: *Zlib, io: Io) void {
    for (0.., self.queue.queue.items) |i, _| {
        var stream = self.queue.queue.items[i];
        if (stream != null)
            _ = c.inflateEnd(&stream.?);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Zlib = @fieldParentPtr("interface", interface);

    const get = try self.queue.get(io);
    var stream = if (get == null)
        c.z_stream{}
    else
        get.?;
    defer self.queue.put(io, stream);

    stream.next_in = in.ptr;
    stream.avail_in = @truncate(in.len);
    stream.next_out = out.ptr;
    stream.avail_out = @truncate(out.len);

    var res = c.inflateInit(&stream);

    res = c.inflate(&stream, c.Z_FINISH);
    if (res < 0) {
        std.debug.print("zlib inflate error code: {s}\n", .{c.zError(res)});
        return Decomp.Error.ReadFailed;
    }
    return stream.total_out;
}

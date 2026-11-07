const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Zstd = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue(c.z_stream),

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Zstd {
    return .{
        .alloc = alloc,

        .queue = try .init(alloc, try std.Thread.getCpuCount()),
    };
}
pub fn deinit(self: *Zstd, io: Io) void {
    for (0.., self.queue.queue.items) |i, _| {
        var stream = self.queue.queue.items[i];
        if (stream != null)
            _ = c.inflateEnd(&stream.?);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Zstd = @fieldParentPtr("interface", interface);

    var stream = blk: {
        var stream = try self.queue.get(io);
        if (stream == null)
            break :blk c.z_stream{};
        _ = c.inflateReset(&stream.?);
        break :blk stream.?;
    };
    defer self.queue.put(io, stream);

    stream.next_in = in.ptr;
    stream.avail_in = @truncate(in.len);
    stream.next_out = out.ptr;
    stream.avail_out = @truncate(out.len);

    const res = c.inflate(&stream, c.Z_FULL_FLUSH);
    if (res < 0) {
        std.debug.print("zlib error code: {s}\n", .{c.zError(res)});
        return Decomp.Error.ReadFailed;
    }
    return stream.total_out;
}

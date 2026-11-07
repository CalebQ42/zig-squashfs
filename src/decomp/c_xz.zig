const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Lzma = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue(c.lzma_stream),

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Lzma {
    return .{
        .alloc = alloc,

        .queue = try .init(alloc, try std.Thread.getCpuCount()),
    };
}
pub fn deinit(self: *Lzma, io: Io) void {
    for (0.., self.queue.queue.items) |i, _| {
        var stream = self.queue.queue.items[i];
        if (stream != null)
            _ = c.lzma_end(&stream.?);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Lzma = @fieldParentPtr("interface", interface);

    var stream = blk: {
        var stream = try self.queue.get(io);
        if (stream == null)
            stream = c.lzma_stream{};
        break :blk stream.?;
    };
    defer self.queue.put(io, stream);

    stream.next_in = in.ptr;
    stream.avail_in = in.len;
    stream.next_out = out.ptr;
    stream.avail_out = out.len;

    var res = c.lzma_stream_decoder(&stream, 10 * 1024 * 1024, 0);
    if (res != c.LZMA_OK) {
        std.debug.print("lzma error code: {}\n", .{res});
        return Decomp.Error.ReadFailed;
    }

    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);

    if (res != c.LZMA_STREAM_END) {
        std.debug.print("lzma error code: {}\n", .{res});
        return Decomp.Error.ReadFailed;
    }

    return stream.total_out;
}

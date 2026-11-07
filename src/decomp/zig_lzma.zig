const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Lzma = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue([]u8),

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
    for (self.queue.queue.items) |buf| {
        if (buf != null)
            self.alloc.free(buf.?);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(d: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Lzma = @fieldParentPtr("interface", d);

    var buf = blk: {
        const buf = try self.queue.get(io);
        if (buf == null)
            break :blk try self.alloc.alloc(u8, 10 * 1024);
        break :blk buf.?;
    };
    defer self.queue.put(io, buf);

    var in_rdr: Io.Reader = .fixed(in);

    var decomp = std.compress.lzma.Decompress.initOptions(&in_rdr, self.alloc, buf, .{}, 10 * 1024 * 1024) catch return error.ReadFailed;
    defer {
        buf = decomp.takeBuffer();
        decomp.deinit();
    }

    return decomp.reader.readSliceShort(out);
}

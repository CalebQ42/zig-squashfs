const std = @import("std");
const Io = std.Io;

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Xz = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue([]u8),

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Xz {
    return .{
        .alloc = alloc,

        .queue = try .init(alloc, try std.Thread.getCpuCount()),
    };
}
pub fn deinit(self: *Xz, io: Io) void {
    for (self.queue.queue.items) |buf| {
        if (buf != null)
            self.alloc.free(buf.?);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(d: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Xz = @fieldParentPtr("interface", d);

    var buf = blk: {
        const buf = try self.queue.get(io);
        if (buf == null)
            break :blk try self.alloc.alloc(u8, 10 * 1024);
        break :blk buf.?;
    };
    defer self.queue.put(io, buf);

    var in_rdr: Io.Reader = .fixed(in);

    var decomp = std.compress.xz.Decompress.init(&in_rdr, self.alloc, buf) catch return error.ReadFailed;
    defer {
        buf = decomp.takeBuffer();
        decomp.deinit();
    }

    return decomp.reader.readSliceShort(out);
}

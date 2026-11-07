const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Zstd = @This();

alloc: std.mem.Allocator,

queue: ResourceQueue(*c.ZSTD_DCtx),

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
    for (self.queue.queue.items) |ctx| {
        if (ctx != null)
            _ = c.ZSTD_freeDCtx(ctx);
    }
    self.queue.deinit(self.alloc, io);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Zstd = @fieldParentPtr("interface", interface);

    const ctx = blk: {
        const ctx = try self.queue.get(io);
        if (ctx == null)
            break :blk c.ZSTD_createDCtx().?;
        _ = c.ZSTD_DCtx_reset(ctx, c.ZSTD_reset_session_only);
        break :blk ctx.?;
    };
    defer self.queue.put(io, ctx);

    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) > 0) {
        std.debug.print("zstd error: {s}\n", .{c.ZSTD_getErrorName(res)});
        return Decomp.Error.ReadFailed;
    }
    return res;
}

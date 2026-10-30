const std = @import("std");
const Io = std.Io;

const c = @import("c");

const decomp = @import("../decomp.zig");

const Zstd = @This();

queue: Io.Queue(*c.ZSTD_DCtx),
queue_buf: [16]*c.ZSTD_DCtx,

created: std.atomic.Value(u32) = .init(0),

interface: decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(self: *Zstd) Zstd {
    self.queue = .init(&self.queue_buf);
}
pub fn deinit(self: *Zstd, io: Io) void {
    self.queue.close(io);
    for (self.queue_buf) |ctx| {
        _ = c.ZSTD_freeDCtx(ctx);
    }
}

fn decompress(interface: *decomp, io: Io, in: []u8, out: []u8) decomp.Error!usize {
    const self: *Zstd = @fieldParentPtr("interface", interface);

    if (self.created.raw < self.queue_buf.len) {
        const res = self.created.fetchAdd(1, .releas);
        if (res <= self.queue_buf.len)
            self.queue.putOne(io, c.ZSTD_createDCtx().?) catch return decomp.Error.ReadFailed;
    }

    const ctx = self.queue.getOne(io) catch return decomp.Error.ReadFailed;

    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res)) {
        std.debug.print("zstd error: {s}\n", .{c.ZSTD_getErrorName(res)});
        return decomp.Error.ReadFailed;
    }
    return res;
}

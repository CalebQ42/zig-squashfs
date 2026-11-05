const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");

const Zstd = @This();

alloc: std.mem.Allocator,

queue: Io.Queue(?*c.ZSTD_DCtx),
queue_buf: []?*c.ZSTD_DCtx,

created: std.atomic.Value(u32),

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Zstd {
    const buf = try alloc.alloc(?*c.ZSTD_DCtx, try std.Thread.getCpuCount());
    @memset(buf, null);
    return .{
        .alloc = alloc,

        .queue = .init(buf),
        .queue_buf = buf,

        .created = .init(0),
    };
}
pub fn deinit(self: *Zstd, io: Io) void {
    self.queue.close(io);
    for (self.queue_buf) |ctx| {
        if (ctx != null)
            _ = c.ZSTD_freeDCtx(ctx);
    }
    self.alloc.free(self.queue_buf);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Zstd = @fieldParentPtr("interface", interface);

    const ctx = blk: {
        if (self.created.raw < self.queue_buf.len) {
            const res = self.created.fetchAdd(1, .release);
            if (res <= self.queue_buf.len)
                break :blk c.ZSTD_createDCtx();
        }
        break :blk self.queue.getOne(io) catch return Decomp.Error.ReadFailed;
    };
    defer self.queue.putOne(io, ctx) catch {};
    _ = c.ZSTD_DCtx_reset(ctx, c.ZSTD_reset_session_only);

    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) > 0) {
        std.debug.print("zstd error: {s}\n", .{c.ZSTD_getErrorName(res)});
        return Decomp.Error.ReadFailed;
    }
    return res;
}

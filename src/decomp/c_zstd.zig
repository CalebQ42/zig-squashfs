const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");

const Zstd = @This();

alloc: std.mem.Allocator,

queue: std.ArrayListUnmanaged(?*c.ZSTD_DCtx),
cond: Io.Condition,
mut: Io.Mutex = .init,

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init(alloc: std.mem.Allocator) !Zstd {
    var queue: std.ArrayListUnmanaged(?*c.ZSTD_DCtx) = try .initCapacity(alloc, try std.Thread.getCpuCount());
    return .{
        .alloc = alloc,

        .queue = queue,
    };
}
pub fn deinit(self: *Zstd, io: Io) void {
    self.mut.lockUncancelable(io);

    for (self.queue.items) |ctx| {
        if (ctx != null)
            _ = c.ZSTD_freeDCtx(ctx);
    }
    self.queue.deinit(self.alloc);
}

fn decompress(interface: *Decomp, io: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const self: *Zstd = @fieldParentPtr("interface", interface);

    const ctx = blk: {
        try self.mut.lock(io);

        var pop = self.queue.pop();
        while (pop == null) {
            try self.cond.wait(io, &self.mut) catch |err| {
                self.mut.unlock(io);
                return err;
            };
            pop = self.queue.pop();
        }
        self.mut.unlock(io);

        const ctx = pop.?;
        if (ctx == null)
            break :blk c.ZSTD_createDCtx().?;
        _ = c.ZSTD_DCtx_reset(ctx, c.ZSTD_reset_session_only);
        break :blk ctx.?;
    };
    defer blk: {
        self.mut.lock(io) catch break :blk;
        defer self.mut.unlock(io);

        self.queue.appendAssumeCapacity(ctx);
    }

    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) > 0) {
        std.debug.print("zstd error: {s}\n", .{c.ZSTD_getErrorName(res)});
        return Decomp.Error.ReadFailed;
    }
    return res;
}

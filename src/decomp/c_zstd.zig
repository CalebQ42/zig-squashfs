const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const zstd = std.compress.zstd;
const Node = std.SinglyLinkedList.Node;

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Queue = std.Io.Queue(?*c.ZSTD_DCtx);

const Self = @This();

interface: Decompressor = .{ .decomp_fn = decomp },

io: Io,

ctx: []?*c.ZSTD_DCtx,
ctx_queue: Queue,

pub fn init(alloc: std.mem.Allocator, io: Io) !Self {
    const buf = try alloc.alloc(?*c.ZSTD_DCtx, 20); // TODO: Choose a better number instead of a random one.
    var queue: Queue = .init(buf);
    for (0..20) |_|
        try queue.putOne(io, c.ZSTD_createDCtx());

    return .{
        .io = io,

        .ctx = buf,
        .ctx_queue = queue,
    };
}
pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.ctx_queue.close(self.io);
    for (self.ctx) |ctx|
        _ = c.ZSTD_freeDCtx(ctx);
    alloc.free(self.ctx);
}

fn decomp(d: ?*const Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    // TODO: Fix
    //
    // if (d == null) {
    return statelessDecomp(d, alloc, in, out);
    // }
    // var self: *Self = @fieldParentPtr("interface", @constCast(d.?));

    // const ctx = self.ctx_queue.getOne(self.io) catch return Error.ReadFailed;
    // defer self.ctx_queue.putOne(self.io, ctx) catch {};

    // _ = c.ZSTD_DCtx_reset(ctx, c.ZSTD_reset_session_only);

    // const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    // if (c.ZSTD_isError(res) != 0)
    //     return Error.ReadFailed;
    // return res;
}

// Stateless

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*const Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) != 0)
        return Error.ReadFailed;
    return res;
}

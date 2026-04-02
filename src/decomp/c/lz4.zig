const std = @import("std");

const c = @import("../../c.zig").c;
const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const res = c.LZ4_decompress_fast(in.ptr, out.ptr, @intCast(out.len));
    if (res < 0) return Decompressor.Error.ReadFailed;
    return @abs(res);
}

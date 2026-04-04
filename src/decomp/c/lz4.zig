const std = @import("std");

const c = @import("../../c_libs.zig").c;
const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = .{ .stateless = stateless } },

pub fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const res = c.LZ4_decompress_safe(in.ptr, out.ptr, in.len, out.len);
    if (res > 0) return @abs(res);
    return Decompressor.Error.ReadFailed; // TOOD: Find out what errors can be returned.
}

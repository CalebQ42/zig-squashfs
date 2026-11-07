const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");

const Lz4 = @This();

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

fn decompress(_: *Decomp, _: Io, in: []u8, out: []u8) Decomp.Error!usize {
    const res = c.LZ4_decompress_fast(in.ptr, out.ptr, @bitCast(@as(u32, @truncate(in.len))));
    if (res < 0) {
        std.debug.print("lz4 error code: {}\n", .{res});
        return Decomp.Error.ReadFailed;
    }
    return @abs(res);
}

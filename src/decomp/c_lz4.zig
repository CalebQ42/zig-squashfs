const std = @import("std");

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*const Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
<<<<<<< HEAD
    const res = c.LZ4_decompress_fast(in.ptr, out.ptr, @truncate(out.len));
=======
    const out_len: c_int = @bitCast(@as(u32, @truncate(out.len)));
    const res = c.LZ4_decompress_fast(in.ptr, out.ptr, out_len);
>>>>>>> dfbfbda (Build is working again (on Zig master branch))
    if (res < 0) return Error.ReadFailed;
    return @abs(res);
}

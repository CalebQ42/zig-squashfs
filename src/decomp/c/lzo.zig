const std = @import("std");

const c = @import("c");
const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

pub fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var out_len = out.len;
    const res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &out_len, null);
    return switch (res) {
        c.LZO_E_OK => out_len,
        c.LZO_E_ERROR => Decompressor.Error.ReadFailed,
        c.LZO_E_OUT_OF_MEMORY => Decompressor.Error.OutOfMemory,
        c.LZO_E_NOT_COMPRESSIBLE => Decompressor.Error.ReadFailed,
        c.LZO_E_INPUT_OVERRUN => Decompressor.Error.ReadFailed,
        c.LZO_E_OUTPUT_OVERRUN => Decompressor.Error.WriteFailed,
        c.LZO_E_LOOKBEHIND_OVERRUN => Decompressor.Error.ReadFailed,
        c.LZO_E_EOF_NOT_FOUND => Decompressor.Error.ReadFailed,
        c.LZO_E_INPUT_NOT_CONSUMED => Decompressor.Error.ReadFailed,
        c.LZO_E_NOT_YET_IMPLEMENTED => Decompressor.Error.ReadFailed,
        c.LZO_E_INVALID_ARGUMENT => Decompressor.Error.ReadFailed,
        c.LZO_E_INVALID_ALIGNMENT => Decompressor.Error.ReadFailed,
        c.LZO_E_OUTPUT_NOT_CONSUMED => Decompressor.Error.WriteFailed,
        c.LZO_E_INTERNAL_ERROR => Decompressor.Error.ReadFailed,
        else => Decompressor.Error.ReadFailed,
    };
}

const std = @import("std");

const Decompressor = @import("../decomp.zig");
const c = @import("c.zig").c;

pub const LzoDecompressor = struct { interface: Decompressor = .{ .vtable = .{ .stateless = lzo } } };

fn lzo(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var res = c.lzo_init();
    if (res != 0) return Decompressor.Error.BadInput;
    var out_len: usize = out.len;
    res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &out_len, null);

    return switch (res) {
        c.LZO_E_OK => out_len,
        c.LZO_E_ERROR => error.LzoError,
        c.LZO_E_OUT_OF_MEMORY => Decompressor.Error.OutOfMemory,
        c.LZO_E_NOT_COMPRESSIBLE => error.LzoNotCompressible,
        c.LZO_E_INPUT_OVERRUN => error.LzoInputOverrun,
        c.LZO_E_OUTPUT_OVERRUN => error.LzoOutputOverrun,
        c.LZO_E_LOOKBEHIND_OVERRUN => error.LzoLookbehindOverrun,
        c.LZO_E_EOF_NOT_FOUND => error.LzoEofNotFound,
        c.LZO_E_INPUT_NOT_CONSUMED => Decompressor.Error.OutputTooSmall,
        c.LZO_E_NOT_YET_IMPLEMENTED => error.LzoNotYetImplemented,
        c.LZO_E_INVALID_ARGUMENT => error.LzoInvalidArgument,
        c.LZO_E_INVALID_ALIGNMENT => error.LzoInvalidAlignment,
        c.LZO_E_OUTPUT_NOT_CONSUMED, c.LZO_E_OUTPUT_OVERRUN => Decompressor.Error.OutputTooSmall,
        else => error.UnknownResult,
    };
}

pub const Lz4Decompressor = struct { interface: Decompressor = .{ .vtable = .{ .stateless = lz4 } } };

fn lz4(_: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    const res = c.LZ4_decompress_safe(in.ptr, out.ptr, @intCast(in.len), @intCast(out.len));
    if (res > 0) return @abs(res); // TODO: Find out what error values it can return.
    return error.Lz4DecompressFailed;
}

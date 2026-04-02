const std = @import("std");

const c = @import("../../c.zig").c;
const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var out_len: usize = out.len;
    const res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &out_len, null);
    decodeError(res) catch |err| return lzoErrToDecompErr(err);
    return out_len;
}

inline fn decodeError(res: c_int) Error!void {
    return switch (res) {
        c.LZO_E_OK => {},
        c.LZO_E_EOF_NOT_FOUND => Error.EofNotFound,
        c.LZO_E_INPUT_NOT_CONSUMED => Error.InputNotConsumed,
        c.LZO_E_INPUT_OVERRUN => Error.InputOverrun,
        c.LZO_E_INTERNAL_ERROR => Error.InternalError,
        c.LZO_E_INVALID_ALIGNMENT => Error.InvalidAlignment,
        c.LZO_E_INVALID_ARGUMENT => Error.InvalidArgument,
        c.LZO_E_LOOKBEHIND_OVERRUN => Error.LookbehindOverrun,
        c.LZO_E_NOT_COMPRESSIBLE => Error.NotCompressible,
        c.LZO_E_NOT_YET_IMPLEMENTED => Error.NotYetImplemented,
        c.LZO_E_OUTPUT_NOT_CONSUMED => Error.OutputNotConsumed,
        c.LZO_E_OUTPUT_OVERRUN => Error.OutputOverrun,
        c.LZO_E_OUT_OF_MEMORY => Error.OutOfMemory,
        else => Error.Unknown,
    };
}
inline fn lzoErrToDecompErr(err: Error) Decompressor.Error {
    return switch (err) {
        Error.EofNotFound => Decompressor.Error.ReadFailed,
        Error.InputNotConsumed => Decompressor.Error.ReadFailed,
        Error.InputOverrun => Decompressor.Error.ReadFailed,
        Error.InternalError => Decompressor.Error.ReadFailed,
        Error.InvalidAlignment => Decompressor.Error.ReadFailed,
        Error.InvalidArgument => Decompressor.Error.ReadFailed,
        Error.LookbehindOverrun => Decompressor.Error.ReadFailed,
        Error.NotCompressible => Decompressor.Error.ReadFailed,
        Error.NotYetImplemented => Decompressor.Error.ReadFailed,
        Error.OutputNotConsumed => Decompressor.Error.WriteFailed,
        Error.OutputOverrun => Decompressor.Error.WriteFailed,
        Error.OutOfMemory => Decompressor.Error.OutOfMemory,
        else => Decompressor.Error.ReadFailed,
    };
}

const Error = error{
    EofNotFound,
    InputNotConsumed,
    InputOverrun,
    InternalError,
    InvalidAlignment,
    InvalidArgument,
    LookbehindOverrun,
    NotCompressible,
    NotYetImplemented,
    OutputNotConsumed,
    OutputOverrun,
    OutOfMemory,
    Unknown,
};

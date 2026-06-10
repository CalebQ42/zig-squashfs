const std = @import("std");

const c = @import("c");

const Error = @import("decomp.zig").Error;

pub fn zlib(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.z_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.inflateInit(&stream);
    if (res != c.Z_OK)
        return Error.DecompressionFailed;
    res = c.inflate(&stream, c.Z_FULL_FLUSH);
    if (res != c.Z_OK)
        return Error.DecompressionFailed;
    return stream.total_out;
}
pub fn lzma(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.lzma_auto_decoder(&stream, 0, 0);
    if (res != c.LZMA_OK)
        return Error.DecompressionFailed;
    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream);
    if (res != c.LZMA_STREAM_END)
        return Error.DecompressionFailed;
    return stream.total_out;
}
pub fn lz4(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.LZ4_decompress_safe(
        in.ptr,
        out.ptr,
        @intCast(in.len),
        out.len,
    );
    if (res < 0)
        return Error.DecompressionFailed;
    return @abs(res);
}

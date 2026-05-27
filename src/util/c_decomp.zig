const std = @import("std");

const c = @import("c");

const Error = @import("decompress.zig").DecompressionError;

pub fn zlibDecompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var strem: c.zng_stream = .{
        .next_in = in.ptr,
        .avail_in = @truncate(in.len),
        .next_out = out.ptr,
        .avail_out = @truncate(out.len),
    };
    var res = c.zng_inflateInit(&strem);
    if (res != c.Z_OK) return Error.ReadFailed;
    defer _ = c.zng_inflateEnd(&strem);

    res = c.zng_inflate(&strem, c.Z_FULL_FLUSH);
    if (res != c.Z_OK) return Error.ReadFailed;

    return strem.total_out;
}
pub fn lzmaDecompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var strem: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.lzma_auto_decoder(&strem, out.len * 2, 0);
    if (res != c.LZMA_OK) return Error.ReadFailed;
    defer c.lzma_end(&strem);

    while (res == c.LZMA_OK)
        res = c.lzma_code(&strem, c.LZMA_RUN);
    if (res != c.LZMA_FINISH) return Error.ReadFailed;

    return strem.total_out;
}
pub fn lzoDecompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var out_len = out.len;
    const res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &out_len, null);
    if (res != c.LZO_E_OK) return Error.ReadFailed;
    return out_len;
}
pub fn lz4Decompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.LZ4_decompress_safe(
        in.ptr,
        out.ptr,
        @bitCast(@as(u32, @truncate(in.len))),
        @bitCast(@as(u32, @truncate(out.len))),
    );
    if (res < 0) return Error.ReadFailed;
    return @abs(res);
}
pub fn zstdDecompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) != 0)
        return Error.ReadFailed;
    return res;
}

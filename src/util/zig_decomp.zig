const std = @import("std");
const Reader = std.Io.Reader;
const flate = std.compress.flate;
const zstd = std.compress.zstd;
const xz = std.compress.xz;
const lzma = std.compress.lzma;

const Error = @import("decompress.zig").DecompressionError;

pub fn zlibDecompress(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var buf: [flate.max_window_len]u8 = undefined;

    var rdr: Reader = .fixed(in);
    var decomp: flate.Decompress = .init(&rdr, .zlib, &buf);

    return decomp.reader.readSliceShort(out);
}
pub fn zstdDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const buf = try alloc.alloc(u8, in.len + zstd.block_size_max);
    defer alloc.free(buf);

    var rdr: Reader = .fixed(in);
    var decomp: zstd.Decompress = .init(&rdr, buf, .{ .window_len = in.len });

    return decomp.reader.readSliceShort(out);
}
pub fn lzmaDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Reader = .fixed(in);
    var decomp: lzma.Decompress = .initOptions(&rdr, alloc, &[0]u8{}, .{}, 2 * out.len);
    defer decomp.deinit();

    return decomp.reader.readSliceShort(out);
}
pub fn xzDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Reader = .fixed(in);
    var decomp: xz.Decompress = .init(&rdr, alloc, &[0]u8{});
    defer decomp.deinit();

    return decomp.reader.readSliceShort(out);
}

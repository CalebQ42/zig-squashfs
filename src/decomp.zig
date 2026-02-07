const std = @import("std");
const Reader = std.Io.Reader;

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const DecompFn = *const fn (alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize; // TODO: replace anyerror to definitive error types.

// pub const DecompressError = error{
//     ReadFailed,
//     anyerror,
// };

pub fn gzipDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, out.len);
    defer alloc.free(buf);
    var decomp = std.compress.flate.Decompress.init(&rdr, .zlib, buf);
    return decomp.reader.readSliceShort(out);
}

pub fn lzmaDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.lzma.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}

pub fn xzDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.xz.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}

pub fn zstdDecompress(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(buf);
    var decomp = std.compress.zstd.Decompress.init(&rdr, buf, .{});
    return decomp.reader.readSliceShort(out) catch |err| {
        return decomp.err orelse err;
    };
}

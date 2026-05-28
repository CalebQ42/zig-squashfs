const std = @import("std");
const Io = std.Io;

const config = @import("config");

const c_decomp = @import("c_decomp.zig");
const zig_decomp = @import("zig_decomp.zig");

pub const Error = Io.Reader.Error || std.mem.Allocator.Error;

pub const Fn = *const fn (alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub fn getDecompressFn(t: CompressionType) !Fn {
    return if (config.use_zig_decomp) switch (t) {
        .lzo => error.LzoUnsupported,
        .lz4 => error.Lz4Unsupported,
        .gzip => zig_decomp.zlibDecompress,
        .lzma => zig_decomp.lzmaDecompress,
        .xz => zig_decomp.xzDecompress,
        .zstd => zig_decomp.zstdDecompress,
    } else switch (t) {
        .gzip => c_decomp.zlibDecompress,
        .lzma => c_decomp.lzmaDecompress,
        .lzo => if (config.allow_lzo) c_decomp.lzoDecompress else error.LzoUnsupported,
        .xz => c_decomp.lzmaDecompress,
        .lz4 => c_decomp.lz4Decompress,
        .zstd => c_decomp.zstdDecompress,
    };
}

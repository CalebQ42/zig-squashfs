const std = @import("std");

const options = @import("options");

const c_decomp = @import("c_decomp.zig");
const zig_decomp = @import("zig_decomp.zig");

pub const Error = error{} || std.Io.Reader.UnlimitedAllocError;

pub const Enum = enum(u16) {
    zlib = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Fn = *const fn (std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub fn DecompFn(comp: Enum) !Fn {
    return if (options.use_zig_decomp)
        switch (comp) {
            .zlib => zig_decomp.zlibDecompress,
            .lzma => zig_decomp.lzmaDecompress,
            .xz => zig_decomp.xzDecompress,
            .zstd => zig_decomp.zstdDecompress,
            .lz4 => error.Lz4Unsupported,
            .lzo => error.LzoUnsupported,
        }
    else switch (comp) {
        .zlib => c_decomp.zlibDecompress,
        .lzma, .xz => c_decomp.lzmaDecompress,
        .zstd => c_decomp.zstdDecompress,
        .lz4 => c_decomp.lz4Decompress,
        .lzo => if (options.allow_lzo)
            c_decomp.zstdDecompress
        else
            error.LzoUnsupported,
    };
}

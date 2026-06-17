const std = @import("std");
const build = @import("build_options");

const c = @import("c_decomp.zig");
const zig = @import("zig_decomp.zig");

pub fn getFn(e: Enum) !Fn {
    return switch (e) {
        .gzip => if (build.use_zig_decomp) zig.zlib else c.zlib,
        .lzma => if (build.use_zig_decomp) zig.lzma else c.lzma,
        .lzo => if (build.use_zig_decomp or !build.allow_lzo) error.LzoUnsupported else c.lzo,
        .xz => if (build.use_zig_decomp) zig.xz else c.lzma,
        .lz4 => if (build.use_zig_decomp) error.Lz4Unsupported else c.lz4,
        .zstd => if (build.use_zig_decomp) zig.zstd else c.zstd,
    };
}

// Types

pub const Fn = *const fn (std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub const Enum = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Error = error{
    OutOfMemory,
    DecompressionFailed,
};

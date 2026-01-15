const std = @import("std");
const compress = std.compress;

pub const CompressionType = enum(u16) {
    gzig = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Compressor = enum(u16) {
    zlib = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

const std = @import("std");
const compress = std.compress;

const DecompressError = error{
    LzoUnsupported,
    Lz4Unsupported,
};

pub const CompressionType = enum(u16) {
    zlib = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn decompress(self: CompressionType, alloc: std.mem.Allocator, rdr: anytype, buf: []u8) !usize {
        switch (self) {
            .zlib => {
                const decomp = compress.zlib.decompressor(rdr);
                const cur_read: usize = 0;
                while (cur_read < buf.len) {
                    const red = try decomp.read(buf[cur_read..]);
                    cur_read += red;
                }
                return cur_read;
            },
            .lzma => {
                const decomp = try compress.lzma.decompress(alloc, rdr);
                const cur_read: usize = 0;
                while (cur_read < buf.len) {
                    const red = try decomp.read(buf[cur_read..]);
                    cur_read += red;
                }
                return cur_read;
            },
            .lzo => return DecompressError.LzoUnsupported,
            .xz => {
                const decomp = try compress.xz.decompress(alloc, rdr);
                const cur_read: usize = 0;
                while (cur_read < buf.len) {
                    const red = try decomp.read(buf[cur_read..]);
                    cur_read += red;
                }
                return cur_read;
            },
            .lz4 => return DecompressError.Lz4Unsupported,
            .zstd => {
                const window_buf = 
                const decomp = try compress.zstd.decompressor(rdr, .{
                    .window_buffer = 
                })
            },
        }
    }
};

const std = @import("std");
const compress = std.compress;

const DecompressError = error{
    LzoNotSupported,
    Lz4NotSupported,
};

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn decompress(self: CompressionType, alloc: std.mem.Allocator, rdr: std.io.AnyReader) ![]u8 {
        var out = std.ArrayList(u8).init(alloc);
        defer out.deinit();
        switch (self) {
            .gzip => try compress.zlib.decompress(rdr, out.writer()),
            .lzma => {
                var decomp = try compress.lzma.decompress(alloc, rdr);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
            .lzo => return DecompressError.LzoNotSupported,
            .xz => {
                var decomp = try compress.xz.decompress(alloc, rdr);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
            .lz4 => return DecompressError.Lz4NotSupported,
            .zstd => {
                const buf = try alloc.alloc(u8, compress.zstd.DecompressorOptions.default_window_buffer_len);
                defer alloc.free(buf);
                var decomp = compress.zstd.decompressor(rdr, .{
                    .window_buffer = buf,
                });
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
        }
        return try out.toOwnedSlice();
    }
};

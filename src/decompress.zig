const std = @import("std");
const io = std.io;

const DecompressError = error{
    LzoUnsupported,
    Lz4Unsupported,
};

pub const DecompressType = enum(u16) {
    zlib = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn decompress(self: DecompressType, alloc: std.mem.Allocator, in: io.AnyReader) !std.ArrayList(u8) {
        const out: std.ArrayList(u8) = .init(alloc);
        switch (self) {
            .zlib => try std.compress.zlib.decompress(in, out),
            .lzma => {
                const decomp = try std.compress.lzma.decompress(alloc, in);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1048576);
            },
            .lzo => return DecompressError.LzoUnsupported,
            .xz => {
                const decomp = try std.compress.xz.decompress(alloc, in);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1048576);
            },
            .lz4 => return DecompressError.Lz4Unsupported,
            .zstd => {
                const buf = try alloc.alloc(u8, std.compress.zstd.DecompressorOptions.default_window_buffer_len);
                defer alloc.free(buf);
                const decomp = std.compress.zstd.decompressor(in, .{
                    .window_buffer = buf,
                });
                try decomp.reader().readAllArrayList(&out, 1048576);
            },
        }
        return out;
    }
};

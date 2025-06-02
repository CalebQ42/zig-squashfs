const std = @import("std");
const comp = std.compress;

const DecompressErrors = error{
    LzoUnsupported,
    Lz4Unsupported,
};

pub const Compressor = enum(u16) {
    zlib = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn decompress(self: Compressor, alloc: std.mem.Allocator, reader: anytype, buf: []u8) !usize {
        switch (self) {
            .zlib => {
                var decomp = comp.zlib.decompressor(reader);
                return decomp.reader().readAll(buf);
            },
            .lzma => {
                var decomp = try comp.lzma.decompress(alloc, reader);
                defer decomp.deinit();
                return decomp.reader().readAll(buf);
            },
            .lzo => return DecompressErrors.LzoUnsupported,
            .xz => {
                var decomp = try comp.xz.decompress(alloc, reader);
                defer decomp.deinit();
                return decomp.reader().readAll(buf);
            },
            .lz4 => return DecompressErrors.Lz4Unsupported,
            .zstd => {
                var win_buf: [comp.zstd.DecompressorOptions.default_window_buffer_len]u8 = undefined;
                var decomp = comp.zstd.decompressor(reader, .{ .window_buffer = &win_buf });
                return decomp.reader().read(buf);
            },
        }
    }
};

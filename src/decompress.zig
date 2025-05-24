const std = @import("std");
const io = std.io;
const compress = std.compress;

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

    pub fn decompress(self: DecompressType, alloc: std.mem.Allocator, rdr: io.AnyReader) !std.ArrayList(u8) {
        var out = std.ArrayList(u8).init(alloc);
        errdefer out.deinit();
        switch (self) {
            .zlib => try compress.zlib.decompress(rdr, out.writer()),
            .lzma => {
                var decomp = try compress.lzma.decompress(alloc, rdr);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
            .lzo => return DecompressError.LzoUnsupported,
            .xz => {
                var decomp = try compress.xz.decompress(alloc, rdr);
                defer decomp.deinit();
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
            .lz4 => return DecompressError.Lz4Unsupported,
            .zstd => {
                const buf = try alloc.alloc(u8, compress.zstd.DecompressorOptions.default_window_buffer_len);
                defer alloc.free(buf);
                var decomp = compress.zstd.decompressor(rdr, .{
                    .window_buffer = buf,
                });
                try decomp.reader().readAllArrayList(&out, 1024 * 1024);
            },
        }
        return out;
    }

    pub fn decompressTo(self: DecompressType, alloc: std.mem.Allocator, rdr: io.AnyReader, writer: io.AnyWriter) !void {
        const buf_size: usize = 1024;
        switch (self) {
            .zlib => try compress.zlib.decompress(rdr, writer),
            .lzma => {
                var decomp = try compress.lzma.decompress(alloc, rdr);
                defer decomp.deinit();
                const buf: [buf_size]u8 = {};
                var red = try decomp.read(&buf);
                while (red > 0) : (red = try decomp.read()) {
                    _ = try writer.writeAll(&buf);
                }
            },
            .lzo => return DecompressError.LzoUnsupported,
            .xz => {
                var decomp = try compress.xz.decompress(alloc, rdr);
                defer decomp.deinit();
                const buf: [buf_size]u8 = {};
                var red = try decomp.read(&buf);
                while (red > 0) : (red = try decomp.read()) {
                    _ = try writer.writeAll(&buf);
                }
            },
            .lz4 => return DecompressError.Lz4Unsupported,
            .zstd => {
                const window_buf = try alloc.alloc(u8, compress.zstd.DecompressorOptions.default_window_buffer_len);
                defer alloc.free(window_buf);
                var decomp = compress.zstd.decompressor(rdr, .{
                    .window_buffer = window_buf,
                });
                const buf: [buf_size]u8 = {};
                var red = try decomp.read(&buf);
                while (red > 0) : (red = try decomp.read()) {
                    _ = try writer.writeAll(&buf);
                }
            },
        }
    }
};

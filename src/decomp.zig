const std = @import("std");
const Io = std.Io;

const c = @import("c");
const build = @import("build_config");

pub const Enum = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn func(self: Enum) !Fn {
        return switch (self) {
            .gzip => if (build.zig_decomp) zigZlib else cZlib,
            .lzma => if (build.zig_decomp) zigLzma else cLzma,
            .lzo => if (build.zig_decomp or !build.allow_lzo) error.LzoUnsupported else cLzo,
            .xz => if (build.zig_decomp) zigXz else cXz,
            .lz4 => if (build.zig_decomp) error.Lz4Unsupported else cLz4,
            .zstd => if (build.zig_decomp) zigZstd else cZstd,
        };
    }
};
pub const Fn = *const fn (alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub const Error = Io.Reader.Error || std.mem.Allocator.Error;

// Actual decomp functions

fn zigZlib(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Io.Reader = .fixed(in);
    var decomp: std.compress.flate.Decompress = .init(&rdr, .zlib, &[0]u8{});

    return decomp.reader.readSliceShort(out);
}
fn cZlib(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.z_stream = .{
        .avail_in = @truncate(in.len),
        .next_in = in.ptr,
        .avail_out = @truncate(out.len),
        .next_out = out.ptr,
    };
    const res = c.inflate(&stream, c.Z_FULL_FLUSH);
    if (res != c.Z_OK)
        return Error.ReadFailed;
    return stream.total_out;
}

fn zigLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Io.Reader = .fixed(in);

    var decomp: std.compress.lzma.Decompress = .initOptions(&rdr, alloc, &[0]u8{}, .{}, 0);
    defer decomp.deinit();

    return decomp.reader.readSliceShort(out);
}
fn cLzma(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.lzma_stream = .{
        .avail_in = in.len,
        .next_in = in.ptr,
        .avail_out = out.len,
        .next_out = out.ptr,
    };
    defer c.lzma_end(&stream);

    var res = c.lzma_alone_decoder(&stream, 0);
    if (res != c.LZMA_OK)
        return Error.ReadFailed;

    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);
    if (res != c.LZMA_FINISH)
        return Error.ReadFailed;

    return stream.total_out;
}

fn cLzo(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var res = c.lzo_init();
    if (res != c.LZO_E_OK)
        return Error.ReadFailed;

    var len = out.len;
    res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &len, null);
    if (res != c.LZO_E_OK)
        return Error.ReadFailed;

    return Error.ReadFailed;
}

fn zigXz(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Io.Reader = .fixed(in);

    var decomp: std.compress.xz.Decompress = .init(&rdr, alloc, &[0]u8{});
    defer decomp.deinit();

    return decomp.reader.readSliceShort(out);
}
fn cXz(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.lzma_stream = .{
        .avail_in = in.len,
        .next_in = in.ptr,
        .avail_out = out.len,
        .next_out = out.ptr,
    };
    defer c.lzma_end(&stream);

    var res = c.lzma_stream_decoder(&stream, 0, 0);
    if (res != c.LZMA_OK)
        return Error.ReadFailed;

    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);
    if (res != c.LZMA_FINISH)
        return Error.ReadFailed;

    return stream.total_out;
}

fn cLz4(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.LZ4_decompress_safe(in.ptr, out.ptr, @intCast(in.len), @intCast(out.len));
    if (res < 0) return Error.ReadFailed;

    return @abs(res);
}

fn zigZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Io.Reader = .fixed(in);

    const buf = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(buf);

    var decomp: std.compress.zstd.Decompress = .init(&rdr, buf, .{
        .window_len = 1024 * 1024,
    });

    return decomp.reader.readSliceShort(out);
}
fn cZstd(_: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) == 1) {
        std.debug.print("{s}\n", .{c.ZSTD_getErrorName(res)});
        return Error.ReadFailed;
    }
    return res;
}

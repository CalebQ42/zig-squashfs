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
            .lzo => if (build.zig_decomp) error.LzoUnsupported else cLzo,
            .xz => if (build.zig_decomp) zigXz else cXz,
            .lz4 => if (build.zig_decomp) error.Lz4Unsupported else cLz4,
            .zstd => if (build.zig_decomp) zigZstd else cZstd,
        };
    }
};
pub const Fn = *const fn (alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub const Error = Io.Reader.Error;

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
    return 0;
}

fn zigLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var rdr: Io.Reader = .fixed(in);
    var decomp: std.compress.lzma.Decompress = .initOptions(&rdr, alloc, out, .{}, 0);
}
fn cLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}

fn cLzo(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}

fn zigXz(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}
fn cXz(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}

fn cLz4(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}

fn zigZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}
fn cZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return Error.ReadFailed;
}

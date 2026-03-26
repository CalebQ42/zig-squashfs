const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const Decompressor = @import("../decomp.zig");

pub const Gzip = struct {
    interface: Decompressor = .{ .vtable = &.{ .stateless = gzip } },
};

pub fn gzip(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, out.len);
    defer alloc.free(buf);
    var decomp = std.compress.flate.Decompress.init(&rdr, .zlib, buf);
    return decomp.reader.readSliceShort(out);
}

pub const Lzma = struct {
    interface: Decompressor = .{ .vtable = &.{ .stateless = lzma } },
};

pub fn lzma(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.lzma.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}

pub const Xz = struct {
    interface: Decompressor = .{ .vtable = &.{ .stateless = xz } },
};

pub fn xz(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.xz.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}

pub const Zstd = struct {
    interface: Decompressor = .{ .vtable = &.{ .stateless = zstd } },
};

pub fn zstd(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(buf);
    var decomp = std.compress.zstd.Decompress.init(&rdr, buf, .{});
    return decomp.reader.readSliceShort(out) catch |err| {
        return decomp.err orelse err;
    };
}

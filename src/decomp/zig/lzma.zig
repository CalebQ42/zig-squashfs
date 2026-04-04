const std = @import("std");
const lzma = std.compress.lzma;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = .{ .stateless = stateless } },

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .static(in);
    var decomp = try lzma.decompress(alloc, rdr.adaptToOldInterface());
    defer decomp.deinit();
    const len = decomp.read(out) catch |err| return switch (err) {
        error.CorruptInput, error.EndOfStream, error.Overflow => Decompressor.Error.ReadFailed,
        else => err,
    };
    return len;
}

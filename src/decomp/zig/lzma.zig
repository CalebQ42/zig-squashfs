const std = @import("std");
const lzma = std.compress.lzma;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try lzma.decompress(alloc, rdr.adaptToOldInterface());
    defer decomp.deinit();
    return decomp.read(out) catch |err| switch (err) {
        error.CorruptInput, error.EndOfStream, error.Overflow => return Decompressor.Error.ReadFailed,
        else => return err,
    };
}

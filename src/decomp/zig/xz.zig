const std = @import("std");
const xz = std.compress.xz;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .static(in);
    var decomp = try xz.decompress(alloc, rdr.adaptToOldInterface());
    defer decomp.deinit();
    const len = decomp.read(out) catch |err| return switch (err) {
        error.CorruptInput => Decompressor.Error.ReadFailed,
        error.EndOfStream => Decompressor.Error.ReadFailed,
        error.EndOfStreamWithNoError => Decompressor.Error.ReadFailed,
        error.WrongChecksum => Decompressor.Error.ReadFailed,
        error.Unsupported => Decompressor.Error.ReadFailed,
        error.Overflow => Decompressor.Error.WriteFailed,
        else => err,
    };
    return len;
}

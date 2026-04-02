const std = @import("std");
const xz = std.compress.xz;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try xz.decompress(alloc, rdr.adaptToOldInterface());
    defer decomp.deinit();
    return decomp.read(out) catch |err| switch (err) {
        error.CorruptInput,
        error.EndOfStream,
        error.EndOfStreamWithNoError,
        error.WrongChecksum,
        error.Unsupported,
        error.Overflow,
        => Decompressor.Error.ReadFailed,
        else => return err,
    };
}

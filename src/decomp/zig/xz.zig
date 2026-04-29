const std = @import("std");
const xz = std.compress.xz;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, in.len);
    defer alloc.free(buf);

    var decomp = xz.Decompress.init(&rdr, alloc, buf) catch |err|
        return switch (err) {
            error.WrongChecksum => Decompressor.Error.ReadFailed,
            error.NotXzStream => Decompressor.Error.ReadFailed,
            else => @errorCast(err),
        };
    defer decomp.deinit();
    return decomp.reader.readSliceShort(out);
}

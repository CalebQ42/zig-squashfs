const std = @import("std");
const lzma = std.compress.lzma;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, in.len);
    defer alloc.free(buf);

    var decomp = lzma.Decompress.initOptions(&rdr, alloc, buf, .{}, out.len) catch |err|
        return switch (err) {
            error.Overflow => Decompressor.Error.ReadFailed,
            error.CorruptInput => Decompressor.Error.ReadFailed,
            error.InvalidRangeCode => Decompressor.Error.ReadFailed,
            else => @errorCast(err),
        };
    defer decomp.deinit();
    return decomp.reader.readSliceShort(out);
}

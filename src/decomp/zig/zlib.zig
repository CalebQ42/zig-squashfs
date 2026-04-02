const std = @import("std");
const Reader = std.Io.Reader;
const flate = std.compress.flate;

const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const buf = try alloc.alloc(u8, out.len);
    defer alloc.free(buf);
    var rdr: Reader = .fixed(in);

    var decomp = flate.Decompress.init(&rdr, .zlib, buf);
    return decomp.reader.readSliceShort(out);
}

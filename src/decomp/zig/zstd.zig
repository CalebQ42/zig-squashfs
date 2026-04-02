const std = @import("std");
const Reader = std.Io.Reader;
const zstd = std.compress.zstd;

const Decompressor = @import("../../decomp.zig");

const Self = @This();

interface: Decompressor = .{ .vtable = &.{ .stateless = stateless } },

fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const buf = try alloc.alloc(u8, out.len * 2);
    defer alloc.free(buf);
    var rdr: Reader = .fixed(in);

    var decomp = zstd.Decompress.init(&rdr, buf, .{ .window_len = @min(out.len, zstd.default_window_len) });
    return decomp.reader.readSliceShort(out);
}

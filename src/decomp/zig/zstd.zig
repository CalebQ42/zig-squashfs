const std = @import("std");
const zstd = std.compress.zstd;
const Reader = std.Io.Reader;

const Decompressor = @import("../../decomp.zig");

interface: Decompressor = .{ .vtable = .{ .stateless = stateless } },

pub fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const buf = try alloc.alloc(u8, out.len * 2);
    defer alloc.free(buf);
    var rdr: Reader = .static(in);
    var decomp = zstd.Decompress.init(&rdr, buf, .{ .window_len = out.len * 2 });
    return decomp.reader.readSliceShort(out);
}

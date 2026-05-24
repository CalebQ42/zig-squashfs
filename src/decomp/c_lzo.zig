const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const zstd = std.compress.zstd;
const Node = std.SinglyLinkedList.Node;

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Queue = std.Io.Queue(c.lzma_stream);

const Self = @This();

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

interface: Decompressor = .{ .decomp_fn = statelessDecomp },

fn statelessDecomp(_: ?*Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = c.lzo_init();
    var out_len = out.len;
    const res = c.lzo1x_decompress_safe(in.ptr, in.len, out.ptr, &out_len, null);
    if (res != c.LZO_E_OK) return Error.ReadFailed;
    return out_len;
}

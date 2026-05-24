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

fn statelessDecomp(_: ?*const Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };

    var res = c.lzma_alone_decoder(&stream, stream.avail_out * 2);
    if (res != c.LZMA_OK) return Error.ReadFailed;
    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);
    if (res != c.LZMA_FINISH) return Error.ReadFailed;
    return stream.total_out;
}

// lzma_allocator

// fn lzmaAlloc(ptr: ?*anyopaque, size: usize, _: usize) callconv(.c) ?*anyopaque {
//     var alloc: *std.mem.Allocator = @ptrCast(@alignCast(ptr));
//     return alloc.rawAlloc(size, .@"1", 0);
// }
// fn lzmaFree(ptr: ?*anyopaque, mem_ptr: ?*anyopaque) callconv(.c) void {
//     if (mem_ptr == null) return;
//     var alloc: *std.mem.Allocator = @ptrCast(@alignCast(ptr));
//     alloc.free(@as([*]u8, @ptrCast(mem_ptr.?)));
// }

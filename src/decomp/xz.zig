const std = @import("std");
const Reader = std.Io.Reader;
const xz = std.compress.xz;
const Node = std.SinglyLinkedList.Node;

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Self = @This();

const Buffer = struct {
    node: Node,
    buf: []u8,
};

interface: Decompressor = .{ .decomp_fn = decomp },

alloc: std.mem.Allocator,

block_size: u32,
buffers: std.ArrayList(Buffer),
buffer_queue: std.SinglyLinkedList,

pub fn init(alloc: std.mem.Allocator, block_size: u32) !Self {
    return .{
        .alloc = alloc,

        .block_size = block_size,
        .buffers = try .initCapacity(alloc, 5),
    };
}
pub fn deinit(self: Self) void {
    for (self.buffers) |buf|
        self.alloc.free(buf);
    self.buffers.deinit(self.alloc);
}

fn decomp(d: ?*const Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    if (d == null) {
        const buf = try alloc.alloc(u8, in.len * 2);
        defer alloc.free(buf);
        return lzmaDecomp(buf, in, out);
    }
    var self: Self = @fieldParentPtr("interface", d.?);
    const buf_node = self.buffer_queue.popFirst();
    var buf: *Buffer = undefined;
    if (buf_node == null) {
        const new_buf = try self.buffers.addOne(self.alloc);
        new_buf.* = .{ .{}, try self.alloc.alloc(u8, self.block_size + xz.block_size_max) };
        buf = new_buf;
    } else {
        buf = @fieldParentPtr("node", buf_node);
    }
    defer self.buffer_queue.prepend(&buf.node);
    return lzmaDecomp(self.alloc, &buf.buf, in, out);
}

inline fn lzmaDecomp(alloc: std.mem.Allocator, buffer: *[]u8, in: []u8, out: []u8) !usize {
    var rdr: Reader = .fixed(in);
    var d = try xz.Decompress.init(&rdr, alloc, buffer.*);
    defer {
        buffer.* = d.takeBuffer();
        d.deinit();
    }

    return d.reader.readSliceShort(out);
}

// Stateless

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*const Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var buf = try alloc.alloc(u8, in.len);
    defer alloc.free(buf);
    return lzmaDecomp(alloc, &buf, in, out) catch return Error.ReadFailed;
}

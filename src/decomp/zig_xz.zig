const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const xz = std.compress.xz;
const Node = std.SinglyLinkedList.Node;

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Queue = Io.Queue([]u8);

const Self = @This();

const Buffer = struct {
    node: Node,
    buf: []u8,
};

interface: Decompressor = .{ .decomp_fn = decomp },

alloc: std.mem.Allocator,
io: Io,

block_size: u32,
buf: [][]u8,
buf_queue: Queue,

pub fn init(alloc: std.mem.Allocator, io: Io, block_size: u32) !Self {
    const buf = try alloc.alloc([]u8, 20); // TODO: Choose a better number instead of a random one.
    var queue: Queue = .init(buf);
    for (0..20) |_|
        try queue.putOne(io, try alloc.alloc(u8, block_size));

    return .{
        .alloc = alloc,
        .io = io,

        .block_size = block_size,
        .buf = buf,
        .buf_queue = queue,
    };
}
pub fn deinit(self: *Self) void {
    self.buf_queue.close(self.io);
    for (self.buf) |buf|
        self.alloc.free(buf);
    self.alloc.free(self.buf);
}

fn decomp(d: ?*const Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    if (d == null) {
        return statelessDecomp(d, alloc, in, out);
    }
    var self: *Self = @fieldParentPtr("interface", @constCast(d.?));

    var buf = self.buf_queue.getOne(self.io) catch return Error.ReadFailed;
    defer self.buf_queue.putOne(self.io, buf) catch {};

    return xzDecomp(self.alloc, &buf, in, out) catch return Error.ReadFailed;
}

inline fn xzDecomp(alloc: std.mem.Allocator, buffer: *[]u8, in: []u8, out: []u8) !usize {
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
    return xzDecomp(alloc, &buf, in, out) catch return Error.ReadFailed;
}

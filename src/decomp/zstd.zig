const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const zstd = std.compress.zstd;
const Node = std.SinglyLinkedList.Node;

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Queue = std.Io.Queue([]u8);

const Self = @This();

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
        try queue.putOne(io, try alloc.alloc(u8, block_size + zstd.block_size_max));

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
        const buf = try alloc.alloc(u8, in.len * 2);
        defer alloc.free(buf);
        return zstdDecomp(buf, in, out);
    }
    var self: *Self = @fieldParentPtr("interface", @constCast(d.?));

    const buf = self.buf_queue.getOne(self.io) catch return Error.ReadFailed;
    defer self.buf_queue.putOne(self.io, buf) catch {};

    return zstdDecomp(buf, in, out);
}

inline fn zstdDecomp(buffer: []u8, in: []u8, out: []u8) !usize {
    var rdr: Reader = .fixed(in);
    var d = zstd.Decompress.init(&rdr, buffer, .{ .window_len = @truncate(out.len) });

    return d.reader.readSliceShort(out);
}

// Stateless

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*const Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    _ = alloc;
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) == 1)
        return Error.ReadFailed;
    return res;
    // const buf = try alloc.alloc(u8, out.len + zstd.block_size_max);
    // defer alloc.free(buf);
    // return zstdDecomp(buf, in, out);
}

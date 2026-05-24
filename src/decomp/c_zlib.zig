const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const zstd = std.compress.zstd;
const Node = std.SinglyLinkedList.Node;

const c = @import("c");

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

const Queue = std.Io.Queue(c.zng_stream);

const Self = @This();

interface: Decompressor = .{ .decomp_fn = decomp },

io: Io,

ctx: []c.zng_stream,
ctx_queue: Queue,

pub fn init(alloc: std.mem.Allocator, io: Io) !Self {
    const buf = try alloc.alloc(c.zng_stream, 20); // TODO: Choose a better number instead of a random one.
    var queue: Queue = .init(buf);
    for (0..20) |_|
        try queue.putOne(io, .{});

    return .{
        .io = io,

        .ctx = buf,
        .ctx_queue = queue,
    };
}
pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.ctx_queue.close(self.io);
    alloc.free(self.ctx);
}

fn decomp(d: ?*Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    if (d == null) {
        return statelessDecomp(d, alloc, in, out);
    }
    var self: *Self = @fieldParentPtr("interface", @constCast(d.?));

    var stream = self.ctx_queue.getOne(self.io) catch return Error.ReadFailed;
    defer self.ctx_queue.putOne(self.io, stream) catch {};

    stream.next_in = in.ptr;
    stream.avail_in = @truncate(in.len);
    stream.next_out = out.ptr;
    stream.avail_out = @truncate(out.len);

    try zlibDecomp(&stream);

    return stream.total_out;
}

inline fn zlibDecomp(stream: *c.zng_stream) !void {
    _ = c.zng_inflateReset(stream);

    const res = c.zng_inflate(stream, c.Z_FULL_FLUSH);
    if (res != c.Z_OK) return Error.ReadFailed;
}

// Stateless

pub const stateless_decompressor: Decompressor = .{ .decomp_fn = statelessDecomp };

fn statelessDecomp(_: ?*Decompressor, _: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    var stream: c.zng_stream = .{
        .next_in = in.ptr,
        .avail_in = @truncate(in.len),
        .next_out = out.ptr,
        .avail_out = @truncate(out.len),
    };
    try zlibDecomp(&stream);
    return stream.total_out;
}

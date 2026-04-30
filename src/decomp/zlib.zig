const std = @import("std");
const Reader = std.Io.Reader;
const flate = std.compress.flate;

const Decompressor = @import("../util/decompressor.zig");
const Error = Decompressor.Error;

pub fn Zlib(stateless: bool) type {
    return if (stateless)
        struct {
            const Self = @This();

            interface: Decompressor = .{ .decomp_fn = decomp },

            const init: Self = .{};

            fn decomp(_: *?Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
                const buf = try alloc.alloc(u8, in.len * 2);
                defer alloc.free(buf);
                return zlibDecomp(buf, in, out);
            }
        }
    else
        struct {
            const Self = @This();

            interface: Decompressor = .{ .decomp_fn = decomp },

            alloc: std.mem.Allocator,

            block_size: u32,
            buffers: std.ArrayList([]u8),
            buffer_queue: std.SinglyLinkedList,

            pub fn init(alloc: std.mem.Allocator, block_size: u32) !Self {
                return .{
                    .alloc = alloc,

                    .block_size = block_size,
                    .buffers = try .initCapacity(alloc, 20),
                };
            }
            pub fn deinit(self: Self) void {
                for (self.buffers) |buf|
                    self.alloc.free(buf);
            }
        };
}

inline fn zlibDecomp(buffer: []u8, in: []u8, out: []u8) !usize {
    var rdr: Reader = .fixed(in);
    var decomp = flate.Decompress.init(&rdr, .zlib, buffer);

    return decomp.reader.readSliceShort(out);
}

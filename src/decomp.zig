const std = @import("std");

const Decompressor = @This();

pub const Error = error{
    OutOfMemory,
    BadInput,
    OutputTooSmall,
};

vtable: *const struct {
    decompress: *const fn (*Decompressor, []u8, []u8) Error!usize = DefaultDecompress,
    stateless: *const fn (std.mem.Allocator, []u8, []u8) Error!usize,
},

pub fn decompress(self: *Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.decompress(self, in, out);
}

fn DefaultDecompress(self: *Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.stateless(std.heap.smp_allocator, in, out);
}

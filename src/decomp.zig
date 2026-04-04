const std = @import("std");

pub const StatelessDecomp = *const fn (std.mem.Allocator, in: []u8, out: []u8) Error!usize;

pub const Error = error{
    OutOfMemory,
    EndOfStream,
    ReadFailed,
    WriteFailed,
};

const Decompressor = @This();

alloc: std.mem.Allocator = std.heap.smp_allocator,
vtable: *const struct {
    decompress: *const fn (*const Decompressor, in: []u8, out: []u8) Error!usize = defaultDecompress,
    stateless: StatelessDecomp,
},

pub fn decompress(self: *const Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.decompress(self, in, out);
}

fn defaultDecompress(self: *const Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.stateless(self.alloc, in, out);
}

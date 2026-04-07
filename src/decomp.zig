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

/// Create a copy of the decompressor using it's stateless function and the new allocator.
pub fn statelessCopy(self: Decompressor, alloc: std.mem.Allocator) Decompressor {
    return &.{ .alloc = alloc, .vtable = &.{ .stateless = self.vtable.stateless } };
}

pub fn decompress(self: *const Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.decompress(self, in, out);
}

fn defaultDecompress(self: *const Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.stateless(self.alloc, in, out);
}

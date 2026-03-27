const std = @import("std");

const Error = error{
    OutOfMemory,
    EndOfStream,
    ReadFailed,
    WriteFailed,
};

const Decompressor = @This();

alloc: std.mem.Allocator = std.heap.page_allocator,
vtable: *struct {
    decompress: *const fn (*Decompressor, in: []u8, out: []u8) Error!usize = defaultDecompress,
    stateless: *const fn (std.mem.Allocator, in: []u8, out: []u8) Error!usize,
},

pub fn decompress(self: *Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.decompress(self, in, out);
}

fn defaultDecompress(self: *Decompressor, in: []u8, out: []u8) Error!usize {
    return self.vtable.stateless(self.alloc, in, out);
}

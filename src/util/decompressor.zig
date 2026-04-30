//! A decompression interface

const std = @import("std");

const Decompressor = @This();

pub const Error = std.Io.Reader.StreamError || std.mem.Allocator.Error;

/// The actual decompression function.
/// If the given decompressor is null, then the decompression should be done "stateless" without lasting allocations.
decomp_fn: *fn (?*Decompressor, std.mem.Allocator, in: []u8, out: []u8) Error!usize,

pub fn Decompress(self: *Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    return self.decomp_fn(self, alloc, in, out);
}

pub fn StatelessDecompression(self: Decompressor, alloc: std.mem.Allocator, in: []u8, out: []u8) Error!usize {
    return self.decomp_fn(null, alloc, in, out);
}

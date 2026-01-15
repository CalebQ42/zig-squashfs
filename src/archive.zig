//! A squashfs archive read from a file.
//! Can be used to directly access File's contents or extract to the filesystem.

const std = @import("std");
const File = std.fs.File;

const Superblock = @import("super.zig").Superblock;
const OffsetFile = @import("util/offset_file.zig");

const Archive = @This();

// 4 Gigs
const MIN_MEM_SIZE = 4 * 1024 * 1024 * 1024;

parent_alloc: std.mem.Allocator,
alloc: std.heap.FixedBufferAllocator,
fixed_buf: []u8,
fil: OffsetFile,

super: Superblock,

/// Default settings using std.Thread.getCpuCount() threads and the minimum of 4gb or half of system memory for memory usage.
pub fn init(alloc: std.mem.Allocator, fil: File) !Archive {
    return initAdvanced(
        alloc,
        fil,
        0,
        try std.Thread.getCpuCount(),
        @min(MIN_MEM_SIZE, std.process.totalSystemMemory() / 2),
    );
}
/// Create the Archive dictating the amount of threads & memory used.
/// If trying to extract a full archive, a large memory size & thread count could help.
/// If you're planning on only interacting with a small number of files, it should be fine to use few threads and a small memory size.
pub fn initAdvanced(alloc: std.mem.Allocator, fil: File, offset: u64, threads: usize, mem: usize) !Archive {
    _ = threads;
    var super: Superblock = undefined;
    const red = try fil.pread(@ptrCast(&super), offset);
    std.debug.assert(red == @sizeOf(Superblock));
    const fixed_buf = alloc.alloc(u8, mem);
    return .{
        .parent_alloc = alloc,
        .alloc = .init(fixed_buf),
        .fixed_buf = fixed_buf,
        .fil = .init(fil, offset),

        .super = super,
    };
}

pub fn deinit(self: *Archive) void {
    self.parent_alloc.free(self.fixed_buf);
}

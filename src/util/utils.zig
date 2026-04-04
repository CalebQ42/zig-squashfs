const std = @import("std");

const Decompressor = @import("../decomp.zig");
const Inode = @import("../inode.zig");
const MetadataReader = @import("metadata.zig");
const OffsetFile = @import("offset_file.zig");

pub fn pathIsSelf(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len == 1) {
        return switch (path[0]) {
            '.', '/' => true,
            else => false,
        };
    }
    return std.mem.eql(u8, path, "./");
}

pub fn refToInode(alloc: std.mem.Allocator, decomp: *const Decompressor, fil: OffsetFile, inode_start: u64, block_size: u32, ref: Inode.Ref) !Inode {
    var rdr = try fil.readerAt(inode_start + ref.block_start, &[0]u8{});
    var meta: MetadataReader = .init(&rdr.interface, decomp);
    try meta.interface.discardAll(ref.block_offset);
    return .read(alloc, &meta.interface, block_size);
}

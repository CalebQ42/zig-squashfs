//! Miscellaneous utility functions.

const std = @import("std");
const Io = std.Io;

const Inode = @import("../inode.zig");
const Decompressor = @import("decompressor.zig");
const MetadataReader = @import("metadata.zig");
const OffsetFile = @import("offset_file.zig");

/// check is the path is referencing itself ("" or ".").
/// separators must be trimmed before calling this function for it to work properly.
pub fn pathIsSelf(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len > 1) return false;
    return path[0] == '.';
}
/// Creates an Inode from an Inode.Ref.
pub fn inodeFromRef(alloc: std.mem.Allocator, file: OffsetFile, decomp: *Decompressor, inode_start: u64, block_size: u32, ref: Inode.Ref) !Inode {
    var rdr = file.readerAt(inode_start + ref.block_start);
    var meta: MetadataReader = .init(alloc, &rdr, decomp);
    try meta.interface.discardAll(ref.block_offset);

    return .read(alloc, &meta.interface, block_size);
}

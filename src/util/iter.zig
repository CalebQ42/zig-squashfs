const std = @import("std");

const MinimalSuperblock = @import("../archive.zig").MinimalSuperblock;
const Decompressor = @import("../decomp.zig");
const DirEntry = @import("../directory.zig").Entry;
const File = @import("../file.zig");
const Inode = @import("../inode.zig");
const MetadataReader = @import("metadata.zig");
const OffsetFile = @import("offset_file.zig");
const Utils = @import("utils.zig");

const Iter = @This();

file: OffsetFile,
super: MinimalSuperblock,
decomp: Decompressor,

entries: []DirEntry,
idx: usize = 0,

pub fn deinit(self: Iter) void {
    for (self.entries) |ent|
        ent.deinit(self.decomp.alloc);
    self.decomp.alloc.free(self.entries);
}

pub fn next(self: *Iter) !?File {
    if (self.idx >= self.entries.len) return null;
    defer self.idx += 1;

    const entry = self.entries[self.idx];

    const new_name = try self.decomp.alloc.alloc(u8, entry.name.len);
    @memcpy(new_name, entry.name);
    return .{
        .file = self.file,
        .super = self.super,
        .decomp = self.decomp,

        .name = new_name,
        .inode = Utils.readInode(
            self.decomp.alloc,
            &self.decomp,
            self.file,
            self.super.inode_start,
            self.super.block_size,
            entry.block_start,
            entry.block_offset,
        ),
    };
}
pub fn reset(self: *Iter) void {
    self.idx = 0;
}

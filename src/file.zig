const std = @import("std");

const inode = @import("inode.zig");
const Reader = @import("squashfs.zig").Reader;
const MetadataReader = @import("metadata_reader.zig").MetadataReader;
const FileOffsetReader = @import("file_offset_reader.zig").FileOffsetReader;
const DirEntry = @import("directory.zig").DirEntry;

const FileOpenError = error{
    NotFound,
    NotDirectory,
};

pub const File = struct {
    rdr: *Reader,
    inode: inode.Inode,
    name: []const u8,
    dir_entries: []DirEntry = undefined,

    pub fn fromRef(rdr: *Reader, ref: inode.InodeRef, name: []const u8) !File {
        var offset_rdr: FileOffsetReader = .init(rdr.file, rdr.super.inode_table + ref.block_start);
        var meta_rdr: MetadataReader = .init(rdr.super.comp, offset_rdr.any(), rdr.alloc.allocator());
        try meta_rdr.skip(ref.offset);
        const in = try inode.readInode(meta_rdr, rdr.super.block_size, rdr.alloc.allocator());
        return .{
            .rdr = rdr,
            .inode = in,
            .name = name,
        };
    }

    pub fn fromDirEntry(rdr: *Reader, ent: DirEntry) !File {
        var offset_rdr: FileOffsetReader = .init(rdr.file, rdr.super.inode_table + ent.inode_block_start);
        var meta_rdr: MetadataReader = .init(
            rdr.super.comp,
            offset_rdr.any(),
            rdr.alloc,
        );
        try meta_rdr.skip(ent.inode_offset);
        const in = try inode.readInode(meta_rdr, rdr.super.block_size, rdr.alloc.allocator());
        return .{
            .rdr = rdr,
            .inode = in,
            .name = ent.name,
        };
    }

    pub fn open(self: File, path: []const u8) (anyerror || FileOpenError)!File {
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {},
            else => return FileOpenError.NotDirectory,
        }
        const clean_path: []const u8 = if (std.mem.startsWith(u8, path, "/")) {
            return path[1..];
        } else {
            return path;
        };
        const path_split = std.mem.splitAny(u8, clean_path, "/");
    }

    fn readDirEntries(self: *File) (anyerror || FileOpenError)!File {}
};

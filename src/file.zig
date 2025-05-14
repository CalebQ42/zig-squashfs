const inode = @import("inode.zig");
const Reader = @import("squashfs.zig").Reader;
const MetadataReader = @import("metadata_reader.zig").MetadataReader;
const FileOffsetReader = @import("file_offset_reader.zig").FileOffsetReader;

pub const File = struct {
    rdr: *Reader,
    inode: inode.Inode,
    name: []const u8,
    dir_entries: []const void = undefined, //TODO

    pub fn fromRef(ref: inode.InodeRef, name: []const u8, rdr: *Reader) !File {
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
};

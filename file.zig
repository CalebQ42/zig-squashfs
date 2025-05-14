const inode = @import("inode.zig");
const Reader = @import("squashfs.zig").Reader;
const MetadataReader = @import("metadata_reader.zig").MetadataReader;

pub const File = struct {
    rdr: *Reader,
    inode: inode.Inode,
    name: []const u8,
    dir_entries: []const void = undefined, //TODO

    pub fn fromRef(ref: inode.InodeRef, rdr: *Reader) !File {
        var meta_rdr: MetadataReader = .init(rdr.super.comp, rdr: io.AnyReader, alloc: std.mem.Allocator)
    }
};

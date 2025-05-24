const std = @import("std");

const inode = @import("inode/inode.zig");

const Table = @import("table.zig").Table;
const FileHolder = @import("readers/file_holder.zig").FileHolder;
const Superblock = @import("superblock.zig").Superblock;
const File = @import("file.zig").File;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;
const DirEntry = @import("directory.zig").DirEntry;
const FragEntry = @import("readers/data_reader.zig").FragEntry;

/// A squashfs archive reader. Make sure to call deinit().
/// For most actions, you'll want to use the Reader.root File.
pub const Reader = struct {
    alloc: std.mem.Allocator,
    holder: FileHolder,
    super: Superblock,
    root: File,

    frag_table: Table(FragEntry),
    export_table: Table(inode.InodeRef),
    id_table: Table(u32),

    pub fn init(alloc: std.mem.Allocator, filepath: []const u8, offset: u64) !Reader {
        var holder: FileHolder = try .init(filepath, offset);
        const super: Superblock = try holder.reader().readStruct(Superblock);
        try super.validate();
        var out: Reader = .{
            .alloc = alloc,
            .holder = holder,
            .super = super,
            .root = undefined,
            .frag_table = undefined,
            .export_table = undefined,
            .id_table = undefined,
        };
        out.frag_table = .init(
            &out,
            super.frag_table_start,
            super.frag_count,
        );
        out.export_table = .init(
            &out,
            super.export_table_start,
            super.inode_count,
        );
        out.id_table = .init(
            &out,
            super.id_table_start,
            super.id_count,
        );
        out.root = try out.fileFromRef(super.root_ref, "");
        return out;
    }
    pub fn deinit(self: *Reader) void {
        self.root.deinit(self.alloc);
        self.holder.deinit();
    }

    fn fileFromRef(self: *Reader, ref: inode.InodeRef, name: []const u8) !File {
        var offset_rdr = self.holder.readerAt(ref.block_start + self.super.inode_table_start);
        var meta_rdr: MetadataReader = .init(
            self.alloc,
            self.super.decomp,
            offset_rdr.any(),
        );
        defer meta_rdr.deinit();
        try meta_rdr.skip(ref.offset);
        return .{
            .name = name,
            .inode = try .init(
                self.alloc,
                meta_rdr.any(),
                self.super.block_size,
            ),
        };
    }
};

test "root iter" {
    const test_sfs_path = "testing/LinuxPATest.sfs";
    // const test_file_path = "PortableApps/PortableApps.com/Data/PortableAppsMenu.ini";

    var rdr: Reader = try .init(std.testing.allocator, test_sfs_path, 0);
    defer rdr.deinit();
    var rootIter = try rdr.root.iterator(&rdr);
    defer rootIter.deinit();
    while (rootIter.next()) |f| {
        std.debug.print("{s}\n", .{f.name});
    }
}

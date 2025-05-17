const std = @import("std");

const inode = @import("inode/inode.zig");

const FileHolder = @import("readers/file_holder.zig").FileHolder;
const Superblock = @import("superblock.zig").Superblock;
const File = @import("file.zig").File;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;
const DirEntry = @import("directory.zig").DirEntry;

pub const Reader = struct {
    alloc: std.mem.Allocator,
    holder: FileHolder,
    super: Superblock,
    root: File,

    pub fn init(alloc: std.mem.Allocator, filepath: []const u8, offset: u64) !Reader {
        var holder: FileHolder = try .init(filepath, offset);
        const super: Superblock = try holder.reader().readStruct(Superblock);
        try super.validate();
        var out: Reader = .{
            .alloc = alloc,
            .holder = holder,
            .super = super,
            .root = undefined,
        };
        out.root = try out.fileFromRef(super.root_ref, "");
        return out;
    }
    pub fn deinit(self: *Reader) void {
        self.root.deinit(self.alloc);
        self.holder.deinit();
    }

    fn fileFromRef(self: *Reader, ref: inode.InodeRef, name: []const u8) !File {
        var offset_rdr = self.holder.readerAt(ref.block_start + self.super.inode_table_start);
        var meta_rdr: MetadataReader = try .init(
            self.alloc,
            offset_rdr.any(),
            self.super.decomp,
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

test "reader" {
    const test_sfs_path = "testing/LinuxPATest.sfs";
    const test_file_path = "PortableApps/PortableApps.com/Data/PortableAppsMenu.ini";

    var rdr: Reader = try .init(std.testing.allocator, test_sfs_path, 0);
    defer rdr.deinit();
    var fil = try rdr.root.open(&rdr, test_file_path);
    defer fil.deinit(rdr.alloc);

    std.debug.print("{}\n", .{fil});
}

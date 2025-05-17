const std = @import("std");

const inode = @import("inode/inode.zig");

const FileHolder = @import("readers/file_holder.zig").FileHolder;
const Superblock = @import("superblock.zig").Superblock;
const File = @import("file.zig").File;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

pub const Reader = struct {
    arena: std.heap.ArenaAllocator,
    holder: FileHolder,
    super: Superblock,
    root: File,

    pub fn init(alloc: std.mem.Allocator, filepath: []const u8, offset: u64) !Reader {
        var holder: FileHolder = try .init(filepath, offset);
        const super: Superblock = try holder.reader().readStruct(Superblock);
        try super.validate();
        const arena: std.heap.ArenaAllocator = .init(alloc);
        var out: Reader = .{
            .arena = arena,
            .holder = holder,
            .super = super,
            .root = undefined,
        };
        out.root = try out.fileFromRef(super.root_ref, "");
        return out;
    }
    pub fn deinit(self: *Reader) void {
        self.arena.deinit();
        self.holder.deinit();
    }

    fn fileFromRef(self: *Reader, ref: inode.InodeRef, name: []const u8) !File {
        var offset_rdr = self.holder.readerAt(ref.block_start + self.super.inode_table_start);
        var meta_rdr: MetadataReader = try .init(
            self.arena.allocator(),
            offset_rdr.any(),
            self.super.decomp,
        );
        defer meta_rdr.deinit();
        try meta_rdr.skip(ref.offset);
        return .{
            .name = name,
            .inode = try .init(
                self.arena.allocator(),
                meta_rdr.any(),
                self.super.block_size,
            ),
        };
    }
};

test "reader" {
    const test_file_path = "testing/LinuxPATest.sfs";
    var rdr: Reader = try .init(std.testing.allocator, test_file_path, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.root});
}

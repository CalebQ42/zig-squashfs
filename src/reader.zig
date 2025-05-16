const std = @import("std");

const FileHolder = @import("readers/file_holder.zig").FileHolder;
const Superblock = @import("superblock.zig").Superblock;
const File = @import("file.zig").File;

pub const Reader = struct {
    arena: std.heap.ArenaAllocator,
    holder: FileHolder,
    super: Superblock,
    root: File,

    pub fn init(alloc: std.mem.Allocator, filepath: []const u8, offset: u64) !Reader {
        var holder: FileHolder = try .init(filepath, offset);
        const super: Superblock = try holder.anyAt(0).readStruct(Superblock);
        try super.validate();
        const arena: std.heap.ArenaAllocator = .init(alloc);
        var out: Reader = .{
            .arena = arena,
            .holder = holder,
            .super = super,
            .root = undefined,
        };
        out.root = try .fromRef(&out, super.root_ref, "");
        return out;
    }
    pub fn deinit(self: *const Reader) void {
        self.arena.deinit();
        self.holder.deinit();
    }
};

test "reader" {
    const test_file_path = "testing/LinuxPATest.sfs";
    var rdr: Reader = try .init(std.testing.allocator, test_file_path, 0);
    defer rdr.deinit();
    std.debug.print("{}\n", .{rdr.root});
}

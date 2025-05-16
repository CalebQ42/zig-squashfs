const std = @import("std");

const FileHolder = @import("readers/file_holder.zig").FileHolder;
const Superblock = @import("superblock.zig").Superblock;

pub const Reader = struct {
    arena: std.heap.ArenaAllocator,
    holder: FileHolder,
    super: Superblock,

    pub fn init(alloc: std.mem.Allocator, filepath: []const u8, offset: u64) !Reader {
        var holder: FileHolder = try .init(filepath, offset);
        const super: Superblock = try holder.anyAt(0).readStruct(Superblock);
        try super.validate();
        const arena: std.heap.ArenaAllocator = .init(alloc);
        return .{
            .arena = arena,
            .holder = holder,
            .super = super,
        };
    }
    pub fn deinit(self: *const Reader) void {
        self.arena.deinit();
        self.holder.deinit();
    }
};

test "reader" {
    const test_file_path = "testing/LinuxPATest.sfs";
    const rdr: Reader = try .init(std.testing.allocator, test_file_path, 0);
    defer rdr.deinit();
}

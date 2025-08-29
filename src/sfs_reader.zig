const std = @import("std");

const DecompMgr = @import("util/decomp.zig");
const Superblock = @import("super.zig").Superblock;
const Table = @import("table.zig").Table;
const PRdr = @import("util/p_rdr.zig").PRdr;
const InodeRef = @import("inode.zig").Ref;

pub const FragEntry = packed struct {
    block: u64,
    size: u32,
    _: u32,
};

/// A squashfs archive read from a reader of type T.
/// The reader must implement pread([]u8, u64) (such as std.fs.File).
pub fn SfsReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRdr(T),
        decomp: DecompMgr = undefined,

        super: Superblock = undefined,

        /// Initialized after the first use of idTable function.
        id_table: ?Table(u16, T) = null,
        /// Initialized after the first use of fragTable function.
        frag_table: ?Table(FragEntry, T) = null,
        /// Initialized after the first use of inode function.
        export_table: ?Table(InodeRef, T) = null,

        /// Initialize an SfsReader(T). If thread_count is 0, std.Thread.getCpuCount() is used.
        pub fn init(alloc: std.mem.Allocator, rdr: T, offset: u64, thread_count: usize) !Self {
            var super: Superblock = undefined;
            _ = try rdr.pread(std.mem.asBytes(&super), 0);
            try super.validate();
            const decomp: DecompMgr = try .init(alloc, super.comp, if (thread_count == 0) thread_count else try std.Thread.getCpuCount());
            return .{
                .alloc = alloc,
                .rdr = .init(rdr, offset),
                .super = super,
                .decomp = decomp,
            };
        }
        pub fn deinit(self: *Self) void {
            if (self.id_table != null) self.id_table.?.deinit();
            if (self.frag_table != null) self.frag_table.?.deinit();
            if (self.export_table != null) self.export_table.?.deinit();
            self.decomp.deinit();
        }

        pub fn idTable(self: *Self, idx: u16) !u16 {
            if (self.id_table == null) {
                self.id_table = .init(self.alloc, self.rdr, self.super.id_start, &self.decomp, self.super.id_count);
            }
            return self.id_table.?.get(idx);
        }
    };
}

const std = @import("std");

const Inode = @import("inode.zig");
const DecompMgr = @import("util/decomp.zig");
const Superblock = @import("super.zig").Superblock;
const Table = @import("table.zig").Table;
const PRdr = @import("util/p_rdr.zig").PRdr;

pub const FragEntry = packed struct {
    block: u64,
    size: u32,
    _: u32,
};

pub const SfsReaderErrs = error{
    noFragmentTable,
    noExportTable,
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

        /// Initialized after the first use of the idTable function.
        /// Do not use directly.
        id_table: ?Table(u16, T) = null,
        /// Initialized after the first use of the fragTable function.
        /// Do not use directly.
        frag_table: ?Table(FragEntry, T) = null,
        /// Initialized after the first use of the inode function.
        /// Do not use directly. If you do, a given inode is at index (inode number) - 1.
        export_table: ?Table(Inode.Ref, T) = null,

        /// Initialize an SfsReader(T). If thread_count is 0, std.Thread.getCpuCount() is used.
        pub inline fn init(alloc: std.mem.Allocator, rdr: T, offset: u64, thread_count: usize) !Self {
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

        /// Get a uid/gid value from the id table.
        pub fn idTable(self: *Self, idx: u16) !u16 {
            if (self.id_table == null) {
                self.id_table = .init(self.alloc, self.rdr, self.super.id_start, &self.decomp, self.super.id_count);
            }
            return self.id_table.?.get(idx);
        }
        /// Get info about a fragment entry from the fragment table.
        pub fn fragTable(self: *Self, idx: u32) !FragEntry {
            if (self.super.flags.no_frag) return SfsReaderErrs.noFragmentTable;
            if (self.frag_table == null) {
                self.frag_table = .init(self.alloc, self.rdr, self.super.frag_start, &self.decomp, self.super.frag_count);
            }
            return self.id_table.?.get(idx);
        }
        /// Get the inode reference for the given inode number from the export table.
        /// Requires the archive to be exportable.
        pub fn exportTable(self: *Self, num: u32) !Inode.Ref {
            if (!self.super.flags.exportable) return SfsReaderErrs.noExportTable;
            if (self.export_table == null) {
                self.export_table = .init(self.alloc, self.rdr, self.super.export_start, &self.decomp, self.super.inode_count);
            }
            return self.export_table.?.get(num - 1);
        }
        /// Get the Inode for the given inode number using the export table.
        /// Requires the archive to be exportable.
        pub fn inode(self: *Self, num: u32) !Inode {
            if (!self.super.flags.exportable) return SfsReaderErrs.noExportTable;
            if (self.export_table == null) {
                self.export_table = .init(self.alloc, self.rdr, self.super.export_start, &self.decomp, self.super.inode_count);
            }
            return self.export_table.?.get(num - 1);
        }
    };
}

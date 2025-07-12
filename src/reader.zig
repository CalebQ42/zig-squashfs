const std = @import("std");

const Inode = @import("inode.zig");
const Table = @import("table.zig").Table;
const PRead = @import("reader/p_read.zig").PRead;
const FragEntry = @import("fragment.zig").FragEntry;
const Superblock = @import("superblock.zig").Superblock;
const MetadataReader = @import("reader/metadata.zig").MetadataReader;

pub const SfsError = error{
    NotExportable,
};

pub fn SfsReader(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));

    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRead(T),

        super: Superblock = undefined,
        /// ID table. Can be accessed directly
        id_table: Table(u32, T) = undefined,
        /// Fragment table. Can be accessed directly
        frag_table: Table(FragEntry, T) = undefined,
        /// Export table. Each element is an inode referce.
        /// If accessing directly, keep in mind, the table starts at inode 1, as such it's recommended to use the InodeAt function instead.
        export_table: Table(Inode.Ref, T) = undefined,
        root: ?Inode = null,

        pub fn init(alloc: std.mem.Allocator, rdr: T, offset: u64) !Self {
            var out: Self = .{
                .alloc = alloc,
                .rdr = .init(rdr, offset),
            };
            _ = try rdr.pread(std.mem.asBytes(&out.super), 0);
            out.frag_table = .init(alloc, rdr, out.super.frag_start, out.super.frag_count);
            out.id_table = .init(alloc, rdr, out.super.id_start, out.super.id_count);
            out.export_table = .init(alloc, rdr, out.super.export_start, out.super.inode_count);
            return out;
        }
        pub fn deinit(self: *Self) void {
            self.id_table.deinit();
            self.frag_table.deinit();
            self.export_table.deinit();
            // if (self.root != null) self.root.?.deinit();
        }

        /// Returns the inode with the given Inode Number.
        /// Requires the archive to have an export table.
        pub fn inodeAt(self: Self, num: u32) !Inode {
            if (!self.super.flags.has_export) return SfsError.NotExportable;
            const ref = try self.export_table.get(num - 1);
            const meta = MetadataReader(T).init(
                self.alloc,
                self.super.comp,
                self.rdr,
                self.super.inode_start + ref.block,
            );
            try meta.skip(ref.offset);
            return .init(meta, self.alloc, self.super.block_size);
        }
    };
}

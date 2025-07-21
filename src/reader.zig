const std = @import("std");

const Inode = @import("inode.zig");
const File = @import("file.zig").File;
const Table = @import("table.zig").Table;
const PRead = @import("reader/p_read.zig").PRead;
const FragEntry = @import("fragment.zig").FragEntry;
const Superblock = @import("superblock.zig").Superblock;
const ExtractionOptions = @import("extract_options.zig");
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

        pub fn init(alloc: std.mem.Allocator, rdr: T, offset: u64) !Self {
            var out: Self = .{
                .alloc = alloc,
                .rdr = .init(rdr, offset),
            };
            _ = try rdr.pread(std.mem.asBytes(&out.super), 0);
            out.frag_table = .init(alloc, out.rdr, out.super.comp, out.super.frag_start, out.super.frag_count);
            out.id_table = .init(alloc, out.rdr, out.super.comp, out.super.id_start, out.super.id_count);
            out.export_table = .init(alloc, out.rdr, out.super.comp, out.super.export_start, out.super.inode_count);
            return out;
        }
        pub fn deinit(self: *Self) void {
            self.id_table.deinit();
            self.frag_table.deinit();
            self.export_table.deinit();
        }

        /// A representation of the archives root folder.
        pub fn root(self: *Self) !File(T) {
            return .initFromRef(self, self.super.root_ref, "");
        }
        /// Get the file at path. Equivelent to calling open on the root File.
        pub fn open(self: *Self, path: []const u8) !File(T) {
            var rt = try self.root();
            if (path.len == 0 or (path.len == 1 and path[0] == '/') or path.len == 1 and path[0] == '.') return rt;
            defer rt.deinit();
            return rt.open(path);
        }
        /// Extract the entire archive to the given path & with the given options.
        /// Equivelent to calling extract on the root File.
        pub fn extract(self: *Self, op: ExtractionOptions, path: []const u8) !void {
            var rt = try self.root();
            defer rt.deinit();
            return rt.extract(op, path);
        }

        /// Returns the Inode with the given Inode Number.
        /// Requires the archive to have an export table.
        pub fn inodeAt(self: Self, num: u32) !Inode {
            if (!self.super.flags.has_export) return SfsError.NotExportable;
            const ref = try self.export_table.get(num - 1);
            var meta = MetadataReader(T).init(
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

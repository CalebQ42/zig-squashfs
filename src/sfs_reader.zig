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

pub fn SfsReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRdr(T),
        decomp: DecompMgr = undefined,

        super: Superblock = undefined,

        id_table: Table(u16, T) = undefined,
        frag_table: Table(FragEntry, T) = undefined,
        export_table: Table(InodeRef, T) = undefined,

        /// Initialize an SfsReader. rdr must have the function pread([]u8, u64).
        /// If thread_count is 0, std.Thread.getCpuCount() is used.
        pub fn init(alloc: std.mem.Allocator, rdr: T, offset: u64, thread_count: usize) !Self {
            var out: Self = .{
                .alloc = alloc,
                .rdr = .init(rdr, offset),
            };
            _ = try out.rdr.pread(std.mem.asBytes(&out.super), 0);
            out.decomp = try .init(alloc, out.super.comp, if (thread_count == 0) thread_count else try std.Thread.getCpuCount());
            out.id_table = .init(alloc, .init(rdr, offset), out.super.id_start, &out.decomp, out.super.id_count);
            out.frag_table = .init(alloc, .init(rdr, offset), out.super.frag_start, &out.decomp, out.super.frag_count);
            out.export_table = .init(alloc, .init(rdr, offset), out.super.export_start, &out.decomp, out.super.inode_count);
            return out;
        }
        pub fn deinit(self: *Self) void {
            self.id_table.deinit();
            self.frag_table.deinit();
            self.export_table.deinit();
            self.decomp.deinit();
        }
    };
}

const std = @import("std");

const FilePReader = @import("readers/preader.zig").PReader(std.fs.File);
const Compressor = @import("decompress.zig").Compressor;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;
const InodeRef = @import("inode.zig").Ref;

const TableError = error{
    InvalidIndex,
};

pub fn Table(comptime T: anytype) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: FilePReader,
        comp: Compressor,

        /// It's preferred to use get, as table may not have the element you need.
        table: []T,
        total: u32,
        offset: u64,

        pub fn init(alloc: std.mem.Allocator, rdr: FilePReader, comp: Compressor, total_count: u32, offset: u64) Self {
            return .{
                .alloc = alloc,
                .rdr = rdr,
                .comp = comp,
                .table = &[0]T{},
                .total = total_count,
                .offset = offset,
            };
        }
        pub fn deinit(self: Self) void {
            self.alloc.free(self.table);
        }

        /// Get's the element at i, filling the table further if needed.
        /// InodeRef tables have their indexes shifted due to the array starting at inode 1.
        pub fn get(self: *Self, i: u32) !T {
            comptime if (T != InodeRef) {
                if (i >= self.total) {
                    return TableError.InvalidIndex;
                }
                while (i <= self.table.len) {
                    try self.readNextBlock();
                }
                return self.table[i];
            } else { // 0 is reserved for Inodes, so the index *actually* starts at 1
                if (i == 0 or i - 1 >= self.total) {
                    return TableError.InvalidIndex;
                }
                while (i - 1 <= self.table.len) {
                    try self.readNextBlock();
                }
                return self.table[i - 1];
            };
        }

        pub fn readNextBlock(self: *Self) !void {
            const to_read = @min(self.total - self.table.len, comptime 8192 / @sizeOf(T));
            const start = self.table.len;
            if (self.table.len == 0 or !self.alloc.resize(self.table)) {
                const new_table = try self.alloc.alloc(T, self.table.len + to_read);
                @memcpy(new_table[0..self.table.len], self.table);
                self.alloc.free(self.table);
                self.table = new_table;
            }
            const offset = try self.rdr.preadStruct(u64, self.rdr.offset);
            self.rdr.offset += 8;
            const off_rdr = self.rdr.readerAt(offset);
            const meta_rdr: MetadataReader(@TypeOf(off_rdr)) = try .init(self.alloc, self.comp, off_rdr);
            _ = try meta_rdr.readAll(std.mem.sliceAsBytes(self.table[start..]));
        }
    };
}

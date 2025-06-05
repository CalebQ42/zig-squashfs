const std = @import("std");

const FilePReader = @import("preader.zig").PReader(std.fs.File, std.fs.File.PReadError, std.fs.File.pread);
const Compressor = @import("decompress.zig").Compressor;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const TableError = error{
    InvalidIndex,
};

pub fn Table(comptime T: anytype) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: FilePReader,
        comp: Compressor,

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

        pub fn get(self: *Self, i: u32) !T {
            if (i >= self.total) {
                return TableError.InvalidIndex;
            }
            while (i <= self.table.len) {
                try self.readNextBlock();
            }
            return self.table[i];
        }

        pub fn readNextBlock(self: *Self) !void {
            const to_read = @min(self.total - self.table.len, comptime 8192 / @sizeOf(T));
            const start = self.table.len;
            if (!self.alloc.resize(self.table)) {
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

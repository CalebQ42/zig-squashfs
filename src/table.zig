const std = @import("std");

const Reader = @import("reader.zig").Reader;
const DecompressType = @import("decompress.zig").DecompressType;
const FileHolder = @import("readers/file_holder.zig").FileHolder;
const FileOffsetReader = @import("readers/file_holder.zig").FileOffsetReader;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const TableError = error{InvalidIndex};

pub fn Table(
    comptime T: type,
) type {
    return struct {
        alloc: std.mem.Allocator,
        decomp: DecompressType,
        holder: *FileHolder,
        table: []T = &[0]T{},
        offset: u64,
        item_count: u32,

        pub fn init(read: *Reader, offset: u64, item_count: u32) Self {
            return .{
                .alloc = read.alloc,
                .decomp = read.super.decomp,
                .holder = &read.holder,
                .offset = offset,
                .item_count = item_count,
            };
        }
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            alloc.free(self.table);
        }

        pub fn getValue(self: *Self, i: u64) !T {
            if (i >= self.item_count) return TableError.InvalidIndex;
            if (self.table.len - 1 > i) return self.table[i];
            var meta_rdr: MetadataReader = undefined;
            var offset_rdr: FileOffsetReader = undefined;
            var meta_offset: u64 = 0;
            var to_read: u32 = 0;
            while (self.table.len < i) {
                _ = try self.holder.file.preadAll(std.mem.sliceAsBytes(&meta_offset), self.offset);
                self.offset += 8;
                offset_rdr = self.holder.readerAt(meta_offset);
                meta_rdr = .init(self.alloc, self.decomp, offset_rdr.any());
                defer meta_rdr.deinit();
                to_read = @min(self.item_count - self.table.len, comptime blk: {
                    break :blk 8192 / @sizeOf(T);
                });
                if (!self.alloc.resize(self.table, self.table.len + to_read)) {
                    const alloc_size = self.table.len + to_read;
                    self.alloc.free(self.table);
                    self.table = try self.alloc.alloc(T, alloc_size);
                }
                _ = try meta_rdr.any().readAll(std.mem.asBytes(self.table[self.table.len - to_read ..]));
            }
            return self.table[i];
        }
        const Self: type = @This();
    };
}

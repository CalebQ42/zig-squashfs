const std = @import("std");

const Reader = @import("reader.zig").Reader;
const DecompressType = @import("decompress.zig").DecompressType;
const FileHolder = @import("readers/file_holder.zig").FileHolder;
const FileOffsetReader = @import("readers/file_holder.zig").FileOffsetReader;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const TableError = error{InvalidIndex};

/// A lazily read squashfs table.
pub fn Table(
    comptime T: type,
) type {
    return struct {
        decomp: DecompressType,
        table: []T = &[0]T{},
        offset: u64,
        item_count: u32,

        pub fn init(read: *Reader, offset: u64, item_count: u32) Self {
            return .{
                .decomp = read.super.decomp,
                .offset = offset,
                .item_count = item_count,
            };
        }
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            if (self.table.len != 0) alloc.free(self.table);
        }

        pub fn getValue(self: *Self, read: *Reader, i: u64) !T {
            if (i >= self.item_count) return TableError.InvalidIndex;
            if (self.table.len > i) return self.table[i];
            var offset_rdr: FileOffsetReader = undefined;
            var meta_rdr: MetadataReader = undefined;
            var meta_buf: [8]u8 = [1]u8{0} ** 8;
            const meta_offset = std.mem.bytesAsValue(u64, &meta_buf);
            var to_read: u32 = 0;
            while (self.table.len <= i) {
                _ = try read.holder.file.preadAll(&meta_buf, self.offset);
                self.offset += 8;
                offset_rdr = read.holder.readerAt(meta_offset.*);
                meta_rdr = .init(read.alloc, self.decomp, offset_rdr.any());
                defer meta_rdr.deinit();
                to_read = @min(self.item_count - self.table.len, comptime 8192 / @sizeOf(T));
                const alloc_size = self.table.len + to_read;
                if (self.table.len != 0) read.alloc.free(self.table);
                self.table = try read.alloc.alloc(T, alloc_size);
                _ = try meta_rdr.any().readAll(@ptrCast(self.table[self.table.len - to_read ..]));
            }
            return self.table[i];
        }
        const Self: type = @This();
    };
}

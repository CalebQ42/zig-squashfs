const std = @import("std");

const PRead = @import("p_read.zig").PRead;
const Compression = @import("../superblock.zig").Compression;

const MetaHeader = packed struct {
    size: u15,
    uncompressed: bool,
};

pub fn MetadataReader(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "read"));
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        comp: Compression,
        rdr: PRead(T),
        offset: u64,

        block: [8192]u8 = undefined,
        block_size: usize = 0,
        block_offset: u32 = 0,

        pub fn init(alloc: std.mem.Allocator, comp: Compression, rdr: PRead(T), offset: u64) Self {
            return .{
                .alloc = alloc,
                .comp = comp,
                .rdr = rdr,
                .offset = offset,
            };
        }

        fn readNextBlock(self: *Self) !void {
            var hdr: MetaHeader = undefined;
            _ = try self.rdr.pread(std.mem.asBytes(&hdr), self.offset);
            self.offset += 2;
            if (hdr.uncompressed) {
                self.block_size = try self.rdr.pread(self.block[0..hdr.size], self.offset);
            } else {
                self.block_size = try self.comp.decompress(
                    8192,
                    self.alloc,
                    self.rdr.readerAt(self.offset).reader(),
                    &self.block,
                );
            }
            self.offset += hdr.size;
            self.block_offset = 0;
        }

        pub fn skip(self: *Self, offset: u32) !void {
            var skipped: u32 = 0;
            var hdr: MetaHeader = undefined;
            while (offset - skipped >= 8192) {
                _ = try self.rdr.pread(std.mem.asBytes(&hdr), self.offset);
                self.offset += 2 + hdr.size;
                skipped += 8192;
            }
            var to_skip: u32 = 0;
            while (skipped < offset) {
                if (self.block_offset >= self.block_size) try self.readNextBlock();
                to_skip = @min(self.block_size - self.block_offset, offset - skipped);
                self.block_offset += to_skip;
                skipped += to_skip;
            }
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            var cur_red: usize = 0;
            var to_read: usize = 0;
            while (cur_red < buf.len) {
                if (self.block_offset >= self.block_size) try self.readNextBlock();
                to_read = @min(buf.len - cur_red, self.block_size - self.block_offset);
                @memcpy(buf[cur_red .. cur_red + to_read], self.block[self.block_offset .. self.block_offset + to_read]);
                cur_red += to_read;
                self.block_offset += @truncate(to_read);
            }
            return cur_red;
        }
    };
}

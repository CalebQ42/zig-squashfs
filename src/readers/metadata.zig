const std = @import("std");

const Compressor = @import("../decompress.zig").Compressor;

pub fn MetadataReader(
    comptime Reader: type,
) type {
    comptime std.debug.assert(std.meta.hasFn(Reader, "readAll"));
    return struct {
        const Header = packed struct {
            size: u15,
            not_compressed: bool,
        };

        const Self = @This();

        alloc: std.mem.Allocator,
        decomp: Compressor,
        rdr: Reader,
        block: [8192]u8,
        block_size: u16 = 0,
        block_offset: u16 = 0,

        pub fn init(alloc: std.mem.Allocator, decomp: Compressor, rdr: Reader) !Self {
            var out: Self = .{
                .alloc = alloc,
                .decomp = decomp,
                .rdr = rdr,
                .block = undefined,
            };
            try out.readNextBlock();
            return out;
        }

        pub fn skip(self: *Self, to_skip: u16) !void {
            var cur_to_skip = to_skip;
            while (cur_to_skip > (self.block_size - self.block_offset)) {
                try self.readNextBlock();
                cur_to_skip -= self.block_size - self.block_offset;
            }
            self.block_offset += cur_to_skip;
        }

        fn readNextBlock(self: *Self) !void {
            self.block_offset = 0;
            var hdr: Header = undefined;
            _ = try self.rdr.readAll(std.mem.asBytes(&hdr));
            if (hdr.not_compressed) {
                self.block_size = @truncate(try self.rdr.readAll(self.block[0..hdr.size]));
                return;
            }
            var limit_rdr = std.io.limitedReader(self.rdr, hdr.size);
            self.block_size = @truncate(try self.decomp.decompress(self.alloc, limit_rdr.reader(), &self.block));
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            var cur_red: usize = 0;
            while (cur_red < buf.len) {
                if (self.block_offset >= self.block_size) try self.readNextBlock();
                const to_read = @min(self.block_size - self.block_offset, buf.len - cur_red);
                @memcpy(
                    buf[cur_red .. cur_red + to_read],
                    self.block[self.block_offset .. self.block_offset + to_read],
                );
                cur_red += to_read;
                self.block_offset += to_read;
            }
            return cur_red;
        }

        pub fn readAll(self: *Self, buf: []u8) !usize {
            return self.read(buf);
        }
    };
}

const std = @import("std");

const PRdr = @import("p_rdr.zig").PRdr;
const DecompMgr = @import("decomp.zig");

const Header = packed struct {
    size: u15,
    uncompressed: bool,
};

pub fn MetadataReader(comptime T: type) type {
    return struct {
        const Self = @This();

        rdr: PRdr(T),
        offset: u64,
        decomp: *DecompMgr,

        block: [8192]u8 = undefined,
        block_size: usize = 0,
        block_offset: usize = 0,

        pub fn init(rdr: PRdr(T), offset: u64, decomp: *DecompMgr) Self {
            return .{
                .rdr = rdr,
                .offset = offset,
                .decomp = decomp,
            };
        }

        pub fn skip(self: *Self, offset: u16) !void {
            var to_skip = offset;
            if (to_skip > self.block_size - self.block_offset) {
                to_skip -= self.block_size - self.block_offset;
            }
            if (to_skip >= 8192) {
                while (to_skip >= 8192) {
                    self.block_offset = 0;
                    var hdr: Header = undefined;
                    _ = try self.rdr.pread(std.mem.asBytes(&hdr), self.offset);
                    self.offset += @sizeOf(Header) + hdr.size;
                    to_skip -= 8192;
                }
                try self.readBlock();
            }
            self.block_offset += to_skip;
        }
        pub fn read(self: *Self, dat: []u8) !usize {
            var cur_red: usize = 0;
            while (cur_red < dat.len) {
                if (self.block_size == self.block_offset) {
                    try self.readBlock();
                }
                const to_read = @min(dat.len - cur_red, self.block_size - self.block_offset);
                @memcpy(dat[cur_red .. cur_red + to_read], self.block[self.block_offset .. self.block_offset + to_read]);
                cur_red += to_read;
            }
            return cur_red;
        }

        fn readBlock(self: *Self) !void {
            self.block_offset = 0;
            var hdr: Header = undefined;
            _ = try self.rdr.pread(std.mem.asBytes(&hdr), self.offset);
            self.offset += @sizeOf(Header);
            defer self.offset += hdr.size;
            if (hdr.uncompressed) {
                self.block_size = try self.rdr.pread(self.block[0..hdr.size], self.offset);
            } else {
                var tmp: [8192]u8 = undefined;
                _ = try self.rdr.pread(tmp[0..hdr.size], self.offset);
                self.block_size = try self.decomp.decompress(tmp[0..hdr.size], &self.block);
            }
        }
    };
}

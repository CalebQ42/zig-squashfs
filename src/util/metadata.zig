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

        pub fn skip(self: *Self, to_skip: u16) !void {}
        pub fn read(self: *Self, dat: []u8) !usize {}

        fn readBlock(self: *Self) !void {
            self.block_offset = 0;
            var hdr: Header = undefined;
            _ = try self.rdr.pread(std.mem.asBytes(&hdr), self.offset);
            self.offset += @sizeOf(Header);
            defer self.offset += hdr.size;
            if (hdr.uncompressed) {
                self.block_size = try self.rdr.pread(&self.block[0..hdr.size], self.offset);
            } else {
                var tmp: [8192]u8 = undefined;
                _ = try self.rdr.pread(&tmp[0..hdr.size], self.offset);
                self.block_size = try self.decomp.decompress(&tmp[0..hdr.size], self.block);
            }
        }
    };
}

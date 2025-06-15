const std = @import("std");

const CompressionType = @import("../decomp.zig").CompressionType;
const PReader = @import("../util/preader.zig").PReader;

const Header = packed struct {
    size: u15,
    not_compressed: bool,
};

pub fn MetadataReader(comptime T: type) type {
    return struct {
        const OffsetReader = PReader(T).OffsetReader;
        const Self = @This();

        rdr: OffsetReader,
        decomp: CompressionType,

        block: [8192]u8 = undefined,
        block_size: u32 = 0,
        cur_offset: u32 = 0,

        pub fn init(rdr: OffsetReader, decomp: CompressionType) !Self {
            var out: Self = .{ .rdr = rdr, .decomp = decomp };
            try out.readNextBlock();
            return out;
        }

        fn readNextBlock(self: *Self) !void {
            const hdr: Header = undefined;
            _ = try self.rdr.readAll(std.mem.asBytes(&hdr));
            self.cur_offset = 0;
            if (hdr.not_compressed) {
                _ = try self.rdr.readAll(self.block[0..hdr.size]);
                self.block_size = hdr.size;
                return;
            }
            const tempBuf: [8192]u8 = undefined;
            
        }
    };
}

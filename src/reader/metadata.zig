const std = @import("std");

const Compression = @import("../superblock.zig").Compression;

const MetaHeader = packed struct {
    size: u15,
    uncompressed: bool,
};

pub fn MetadataReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        comp: Compression,
        rdr: T,

        block: [8192]u8 = undefined,
        block_size: usize = 0,
        block_offset: u32 = 0,

        pub fn init(alloc: std.mem.Allocator, comp: Compression, rdr: T) !Self {
            var out: Self = .{
                .alloc = alloc,
                .comp = comp,
                .rdr = rdr,
            };
            try out.readNextBlock();
            return out;
        }

        fn readNextBlock(self: *Self) !void {
            const hdr: MetaHeader = undefined;
            _ = try self.rdr.read(std.mem.asBytes(hdr));
            self.block_size = try self.comp.decompress(
                8192,
                self.alloc,
                std.io.limitedReader(self.rdr, hdr.size),
                self.block,
            );
        }
    };
}

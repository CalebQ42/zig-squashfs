const std = @import("std");

const PRead = @import("p_read.zig").Pread;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

pub fn DataReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,

        rdr: PRead(T),
        comp: Compression,
        offsets: []BlockSize,

        file_size: u64,
        block_size: u32,
        sizes: []BlockSize,

        frag: []u8 = undefined,

        pub fn init(
            alloc: std.mem.Allocator,
            rdr: PRead(T),
            comp: Compression,
            init_offset: u64,
            file_size: u64,
            sizes: []BlockSize,
            block_size: u32,
        ) !Self {
            var cur_offset = init_offset;
            const offsets = alloc.alloc(u64, sizes.len);
            for (0..sizes.len) |i| {
                offsets[i] = cur_offset;
                cur_offset += sizes[i].size;
            }
            return .{
                .alloc = alloc,
                .rdr = rdr,
                .comp = comp,
                .offsets = offsets,
                .file_size = file_size,
                .block_size = block_size,
                .sizes = sizes,
            };
        }

        pub fn addFragment(self: *Self, entry: FragEntry, offset: u32) void {
            self.frag = self.alloc.alloc(u8, self.file_size % self.block_size);
            //TODO:
        }
    };
}

const std = @import("std");

pub const BlockSize = packed struct {
    size: u24,
    uncompressed: bool,
    _: u7,
};

pub const File = struct {
    block: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    block_sizes: []BlockSize,

    pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !File {
        var fixed: [16]u8 = undefined;
        _ = try rdr.read(&fixed);
        const frag_idx = std.mem.readInt(u32, fixed[4..8], .little);
        const size = std.mem.readInt(u32, fixed[12..16], .little);
        var blocks: u32 = size / block_size;
        if (size % block_size > 0 and frag_idx != 0xffffffff) {
            blocks += 1;
        }
        const block_sizes = try alloc.alloc(BlockSize, blocks);
        errdefer alloc.free(block_sizes);
        _ = try rdr.read(std.mem.sliceAsBytes(block_sizes));
        return .{
            .block = std.mem.readInt(u32, fixed[0..4], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, fixed[8..12], .little),
            .size = size,
            .block_sizes = block_sizes,
        };
    }
    pub fn hasFragment(self: File) bool {
        return self.frag_idx != 0xffffffff;
    }
};

pub const ExtFile = struct {
    block: u64,
    size: u64,
    sparse: u64,
    hard_link: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    block_sizes: []BlockSize,

    pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !ExtFile {
        var fixed: [40]u8 = undefined;
        _ = try rdr.read(&fixed);
        const size = std.mem.readInt(u64, fixed[8..16], .little);
        const frag_idx = std.mem.readInt(u32, fixed[28..32], .little);
        var blocks: u32 = @truncate(size / block_size);
        if (size % block_size > 0 and frag_idx != 0xffffffff) {
            blocks += 1;
        }
        const block_sizes = try alloc.alloc(BlockSize, blocks);
        errdefer alloc.free(block_sizes);
        _ = try rdr.read(std.mem.sliceAsBytes(block_sizes));
        return .{
            .block = std.mem.readInt(u64, fixed[0..8], .little),
            .size = size,
            .sparse = std.mem.readInt(u64, fixed[16..24], .little),
            .hard_link = std.mem.readInt(u32, fixed[24..28], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, fixed[32..36], .little),
            .xattr_idx = std.mem.readInt(u32, fixed[36..40], .little),
            .block_sizes = block_sizes,
        };
    }
    pub fn hasFragment(self: ExtFile) bool {
        return self.frag_idx != 0xffffffff;
    }
};

const std = @import("std");
const Reader = std.Io.Reader;

pub const BlockSize = packed struct {
    size: u24,
    uncompressed: bool,
    _: u7,
};

pub const File = struct {
    block_start: u32, // bytes 0-3
    frag_idx: u32, // bytes 4-7
    frag_block_offset: u32, // bytes 8-11
    size: u32, // bytes 12-15
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var start: [16]u8 = undefined;
        try rdr.readSliceAll(&start);
        const frag_idx: u32 = std.mem.readInt(u32, start[4..8], .little);
        const size: u32 = std.mem.readInt(u32, start[12..16], .little);
        var num_blocks: u32 = size / block_size;
        if (size % block_size != 0 and frag_idx == 0xFFFFFFFF) num_blocks += 1;
        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);
        return .{
            .block_start = std.mem.readInt(u32, start[0..4], .little),
            .frag_idx = frag_idx,
            .frag_block_offset = std.mem.readInt(u32, start[8..12], .little),
            .size = size,
            .block_sizes = sizes,
        };
    }

    pub fn deinit(self: File, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

pub const ExtFile = struct {
    block_start: u64, // bytes 0-7
    size: u64, // bytes 8-15
    sparse: u64, // bytes 16-23
    hard_links: u32, // bytes 24-27
    frag_idx: u32, // bytes 28-31
    frag_block_offset: u32, // bytes 32-35
    xattr_idx: u32, // bytes 36-39
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !ExtFile {
        var start: [40]u8 = undefined;
        try rdr.readSliceAll(&start);
        const frag_idx: u32 = std.mem.readInt(u32, start[28..32], .little);
        const size: u64 = std.mem.readInt(u64, start[8..16], .little);
        var num_blocks: u32 = @truncate(size / block_size);
        if (size % block_size != 0 and frag_idx == 0xFFFFFFFF) num_blocks += 1;
        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);
        return .{
            .block_start = std.mem.readInt(u64, start[0..8], .little),
            .size = size,
            .sparse = std.mem.readInt(u64, start[16..24], .little),
            .hard_links = std.mem.readInt(u32, start[24..28], .little),
            .frag_idx = frag_idx,
            .frag_block_offset = std.mem.readInt(u32, start[32..36], .little),
            .xattr_idx = std.mem.readInt(u32, start[36..40], .little),
            .block_sizes = sizes,
        };
    }

    pub fn deinit(self: ExtFile, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

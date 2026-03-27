const std = @import("std");
const Reader = std.Io.Reader;

pub const BlockSize = packed struct {
    size: u31,
    uncompressed: bool,
};

pub const File = struct {
    block_start: u32,
    frag_idx: u32,
    block_offset: u32,
    size: u32,
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var buf: [16]u8 = undefined;
        try rdr.readSliceAll(&buf);
        const frag_idx = std.mem.readVarInt(u32, buf[4..8], .little);
        const size = std.mem.readVarInt(u32, buf[12..], .little);
        const sizes_len = size / block_size;
        if (frag_idx != 0xFFFFFFFF and size % block_size > 0)
            sizes_len += 1;
        const sizes = try alloc.alloc(BlockSize, sizes_len);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);
        return .{
            .block_start = std.mem.readVarInt(u32, buf[0..4], .little),
            .frag_idx = frag_idx,
            .block_offset = std.mem.readVarInt(u32, buf[8..12], .little),
            .size = size,
            .block_sizes = sizes,
        };
    }
};

pub const ExtFile = struct {
    block_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    block_offset: u32,
    xattr_idx: u32,
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var buf: [40]u8 = undefined;
        try rdr.readSliceAll(&buf);
        const frag_idx = std.mem.readVarInt(u32, buf[28..32], .little);
        const size = std.mem.readVarInt(u64, buf[8..16], .little);
        const sizes_len = size / block_size;
        if (frag_idx != 0xFFFFFFFF and size % block_size > 0)
            sizes_len += 1;
        const sizes = try alloc.alloc(BlockSize, sizes_len);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);
        return .{
            .block_start = std.mem.readVarInt(u64, buf[0..8], .little),
            .size = size,
            .sparse = std.mem.readVarInt(u64, buf[16..24], .little),
            .hard_links = std.mem.readVarInt(u32, buf[24..28], .little),
            .frag_idx = frag_idx,
            .block_offset = std.mem.readVarInt(u32, buf[32..36], .little),
            .xattr_idx = std.mem.readVarInt(u32, buf[36..40], .little),
            .block_sizes = sizes,
        };
    }
};

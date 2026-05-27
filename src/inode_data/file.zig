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
    frag_offset: u32, // bytes 8-11
    size: u32, // bytes 12-15
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var values = struct {
            block_start: u32, // bytes 0-3
            frag_idx: u32, // bytes 4-7
            frag_offset: u32, // bytes 8-11
            size: u32, // bytes 12-15
        };
        try rdr.readSliceEndian(@TypeOf(values), @ptrCast(&values), .little);

        var num_blocks: u32 = values.size / block_size;
        if (values.size % block_size != 0 and values.frag_idx == 0xFFFFFFFF) num_blocks += 1;
        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .block_start = values.block_start,
            .frag_idx = values.frag_idx,
            .frag_offset = values.frag_offset,
            .size = values.size,
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
    frag_offset: u32, // bytes 32-35
    xattr_idx: u32, // bytes 36-39
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !ExtFile {
        var values = struct {
            block_start: u64, // bytes 0-7
            size: u64, // bytes 8-15
            sparse: u64, // bytes 16-23
            hard_links: u32, // bytes 24-27
            frag_idx: u32, // bytes 28-31
            frag_offset: u32, // bytes 32-35
            xattr_idx: u32, // bytes 36-39
        };
        try rdr.readSliceEndian(@TypeOf(values), @ptrCast(&values), .little);

        var num_blocks: u32 = values.size / block_size;
        if (values.size % block_size != 0 and values.frag_idx == 0xFFFFFFFF) num_blocks += 1;
        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .block_start = values.block_start,
            .size = values.size,
            .sparse = values.sparse,
            .hard_links = values.hard_links,
            .frag_idx = values.frag_idx,
            .frag_offset = values.frag_offset,
            .xattr_idx = values.xattr_idx,
            .block_sizes = sizes,
        };
    }

    pub fn deinit(self: ExtFile, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

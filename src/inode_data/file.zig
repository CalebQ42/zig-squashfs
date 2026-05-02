const std = @import("std");
const Reader = std.Io.Reader;

pub const BlockSize = packed struct(u32) {
    size: u24,
    uncompressed: bool,
    _: u7,
};

const FileRawRead = extern struct {
    block_start: u32,
    frag_idx: u32,
    frag_block_offset: u32,
    size: u32,
};

pub const File = struct {
    block_start: u32,
    frag_idx: u32,
    frag_block_offset: u32,
    size: u32,
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var raw: FileRawRead = undefined;
        try rdr.readSliceEndian(FileRawRead, @ptrCast(&raw), .little);

        var num_blocks: u32 = raw.size / block_size;
        if (raw.size % block_size != 0 and raw.frag_idx == 0xFFFFFFFF)
            num_blocks += 1;

        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .block_start = raw.block_start,
            .frag_idx = raw.frag_idx,
            .frag_block_offset = raw.frag_block_offset,
            .size = raw.size,
            .block_sizes = sizes,
        };
    }

    pub fn deinit(self: File, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

const ExtFileRawRead = extern struct {
    block_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_block_offset: u32,
    xattr_idx: u32,
};

pub const ExtFile = struct {
    block_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_block_offset: u32,
    xattr_idx: u32,
    block_sizes: []BlockSize,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !ExtFile {
        var raw: ExtFileRawRead = undefined;
        try rdr.readSliceEndian(ExtFileRawRead, @ptrCast(&raw), .little);

        var num_blocks: u32 = @truncate(raw.size / block_size);
        if (raw.size % block_size != 0 and raw.frag_idx == 0xFFFFFFFF)
            num_blocks += 1;

        const sizes = try alloc.alloc(BlockSize, num_blocks);
        errdefer alloc.free(sizes);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .block_start = raw.block_start,
            .size = raw.size,
            .sparse = raw.sparse,
            .hard_links = raw.hard_links,
            .frag_idx = raw.frag_idx,
            .frag_block_offset = raw.frag_block_offset,
            .xattr_idx = raw.xattr_idx,
            .block_sizes = sizes,
        };
    }

    pub fn deinit(self: ExtFile, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

const std = @import("std");

pub const BlockSize = packed struct {
    _: u7,
    not_compressed: bool,
    size: u24,
};

pub const File = struct {
    block: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    block_sizes: []BlockSize,

    const Self = @This();
    pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !Self {
        var buf: [16]u8 = undefined;
        _ = try rdr.read(&buf);
        const frag_idx = std.mem.bytesToValue(u32, buf[4..8]);
        const siz = std.mem.bytesToValue(u32, buf[12..16]);
        const to_read: u32 = siz / block_size;
        if (frag_idx == 0xFFFFFFFF and siz % block_size > 0) {
            to_read += 1;
        }
        const file_block_sizes = try alloc.alloc(BlockSize, to_read);
        _ = try rdr.read(std.mem.sliceAsBytes(file_block_sizes));
        return .{
            .block = std.mem.bytesToValue(u32, buf[0..4]),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.bytesToValue(u32, buf[8..12]),
            .size = siz,
            .block_sizes = file_block_sizes,
        };
    }
    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

pub const ExtFile = struct {
    block: u64,
    size: u64,
    // sparse: u64,
    // hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    block_sizes: []BlockSize,

    const Self = @This();
    pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !Self {
        var buf: [40]u8 = undefined;
        _ = try rdr.read(&buf);
        const frag_idx = std.mem.bytesToValue(u32, buf[28..32]);
        const siz = std.mem.bytesToValue(u64, buf[8..16]);
        const to_read: u32 = siz / block_size;
        if (frag_idx == 0xFFFFFFFF and siz % block_size > 0) {
            to_read += 1;
        }
        const file_block_sizes = try alloc.alloc(BlockSize, to_read);
        _ = try rdr.read(std.mem.sliceAsBytes(file_block_sizes));
        return .{
            .block = std.mem.bytesToValue(u64, buf[0..8]),
            .size = siz,
            // .sparse = std.mem.bytesToValue(u64, buf[16..24]),
            // .hard_links = std.mem.bytesToValue(u32, buf[24..28]),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.bytesToValue(u32, buf[32..36]),
            .xattr_idx = std.mem.bytesToValue(u32, buf[36..40]),
            .block_sizes = file_block_sizes,
        };
    }
    pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

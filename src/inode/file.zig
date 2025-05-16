const std = @import("std");
const io = std.io;

pub const BlockSize = packed struct {
    size: u23,
    not_compressed: bool,
    _: u8,
};

pub const FileInode = struct {
    data_start: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    blocks: []const BlockSize,

    pub fn init(alloc: std.mem.Allocator, rdr: io.AnyReader, block_size: u32) !FileInode {
        var fixed_buf = [_]u8{0} ** 16;
        _ = try rdr.readAll(@ptrCast(&fixed_buf));
        const frag_idx = std.mem.bytesToValue(u32, fixed_buf[4..8]);
        const size = std.mem.bytesToValue(u32, fixed_buf[12..16]);
        var block_num = size / block_size;
        if (frag_idx != 0xFFFFFFFF) {
            block_num += 1;
        }
        const blocks = try alloc.alloc(BlockSize, block_num);
        _ = try rdr.readAll(@ptrCast(blocks));
        return .{
            .data_start = std.mem.bytesToValue(u32, fixed_buf[0..4]),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.bytesToValue(u32, fixed_buf[8..12]),
            .size = size,
            .blocks = blocks,
        };
    }
    pub fn deinit(self: FileInode, alloc: std.mem.Allocator) void {
        alloc.free(self.blocks);
    }
};

pub const ExtFileInode = struct {
    data_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    blocks: []const BlockSize,

    pub fn init(alloc: std.mem.Allocator, rdr: io.AnyReader, block_size: u32) !ExtFileInode {
        var fixed_buf = [_]u8{0} ** 40;
        _ = try rdr.readAll(&fixed_buf);
        const size = std.mem.bytesToValue(u64, fixed_buf[8..16]);
        const frag_idx = std.mem.bytesToValue(u32, fixed_buf[28..32]);
        var block_num = size / block_size;
        if (frag_idx != 0xFFFFFFFF) {
            block_num += 1;
        }
        const blocks = try alloc.alloc(BlockSize, block_num);
        _ = try rdr.readAll(@ptrCast(blocks));
        return .{
            .data_start = std.mem.bytesToValue(u64, fixed_buf[0..8]),
            .size = size,
            .sparse = std.mem.bytesToValue(u64, fixed_buf[16..24]),
            .hard_links = std.mem.bytesToValue(u32, fixed_buf[24..28]),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.bytesToValue(u32, fixed_buf[32..36]),
            .xattr_idx = std.mem.bytesToValue(u32, fixed_buf[36..40]),
            .blocks = blocks,
        };
    }
    pub fn deinit(self: ExtFileInode, alloc: std.mem.Allocator) void {
        alloc.free(self.blocks);
    }
};

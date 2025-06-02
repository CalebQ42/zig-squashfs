const std = @import("std");

const DataBlockSize = @import("../inode.zig").DataBlockSize;

const InitFile = packed struct {
    block: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
};

pub const File = struct {
    block: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    block_sizes: []DataBlockSize,
    pub fn read(alloc: std.mem.Allocator, block_size: u32, reader: anytype) !File {
        var init: InitFile = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&init)));
        var block_num = init.size / block_size;
        if (init.frag_idx == 0xFFFFFFFF and init.size % block_size != 0) {
            block_num += 1;
        }
        const out: File = .{
            .block = init.block,
            .frag_idx = init.frag_idx,
            .frag_offset = init.frag_offset,
            .size = init.size,
            .block_sizes = try alloc.alloc(DataBlockSize, block_num),
        };
        _ = try reader.readAll(@alignCast(std.mem.sliceAsBytes(out.block_sizes)));
        return out;
    }
    pub fn deinit(self: File, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};
const InitExtFile = packed struct {
    block: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
};

pub const ExtFile = struct {
    block: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    block_sizes: []DataBlockSize,
    pub fn read(alloc: std.mem.Allocator, block_size: u32, reader: anytype) !ExtFile {
        var init: InitExtFile = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&init)));
        var block_num = init.size / block_size;
        if (init.frag_idx == 0xFFFFFFFF and init.size % block_size != 0) {
            block_num += 1;
        }
        const out: ExtFile = .{
            .block = init.block,
            .size = init.size,
            .sparse = init.sparse,
            .hard_links = init.hard_links,
            .frag_idx = init.frag_idx,
            .frag_offset = init.frag_offset,
            .xattr_idx = init.xattr_idx,
            .block_sizes = try alloc.alloc(DataBlockSize, block_num),
        };
        _ = try reader.readAll(@alignCast(std.mem.sliceAsBytes(out.block_sizes)));
        return out;
    }
    pub fn deinit(self: ExtFile, alloc: std.mem.Allocator) void {
        alloc.free(self.block_sizes);
    }
};

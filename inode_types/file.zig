const std = @import("std");

pub const FileInode = struct {
    start: u32,
    frag_index: u32,
    frag_block_offset: u32,
    size: u32,
    block_sizes: []const u32,
};

pub fn readFileInode(rdr: std.io.AnyReader, block_size: u32) !FileInode {
    const out = FileInode{
        .start = try rdr.readInt(u32, std.builtin.Endian.little),
        .frag_index = try rdr.readInt(u32, std.builtin.Endian.little),
        .frag_block_offset = try rdr.readInt(u32, std.builtin.Endian.little),
        .size = try rdr.readInt(u32, std.builtin.Endian.little),
        .block_sizes = undefined,
    };
    var block_num = out.size / block_size;
    if (out.frag_index != 0xFFFFFFFF and out.size % block_size != 0) {
        block_num += 1;
    }
    return out;
}

pub const ExtFileInode = struct {
    start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_index: u32,
    frag_block_offset: u32,
    xattr_index: u32,
    block_sizes: []const u32,
};

pub fn readExtFileInode(rdr: std.io.AnyReader, block_size: u32) !ExtFileInode {
    const out = ExtFileInode{
        .start = try rdr.readInt(u64, std.builtin.Endian.little),
        .size = try rdr.readInt(u64, std.builtin.Endian.little),
        .sparse = try rdr.readInt(u64, std.builtin.Endian.little),
        .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
        .frag_index = try rdr.readInt(u32, std.builtin.Endian.little),
        .frag_block_offset = try rdr.readInt(u32, std.builtin.Endian.little),
        .xattr_index = try rdr.readInt(u32, std.builtin.Endian.little),
        .block_sizes = undefined,
    };
    var block_num = out.size / block_size;
    if (out.frag_index != 0xFFFFFFFF and out.size % block_size != 0) {
        block_num += 1;
    }
    //TODO: stuff
    return out;
}

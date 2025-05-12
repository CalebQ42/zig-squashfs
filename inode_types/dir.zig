const std = @import("std");
const io = std.io;

pub const DirInode = packed struct {
    dir_block_start: u32,
    hard_links: u32,
    dir_table_size: u16,
    dir_block_offset: u16,
    parent_inode_num: u32,
};

pub fn readDirInode(rdr: io.AnyReader) !DirInode {
    return try rdr.readStruct(DirInode);
}

pub const DirIndex = struct {
    dir_header_offset: u32,
    dir_table_offset: u32,
    name_size: u32,
    name: []const u8,
};

fn readDirIndex(rdr: io.AnyReader) !DirIndex {
    const out = DirIndex{
        .dir_header_offset = try rdr.readInt(u32, std.builtin.Endian.little),
        .dir_table_offset = try rdr.readInt(u32, std.builtin.Endian.little),
        .name_size = try rdr.readInt(u32, std.builtin.Endian.little),
        .name = undefined,
    };
    const buf = try std.heap.page_allocator.alloc(u8, out.name_size);
    defer std.heap.page_allocator.free(buf);
    try rdr.read(buf);
    out.name = buf[0..];
    return out;
}

pub const ExtDirInode = struct {
    hard_links: u32,
    dir_table_size: u32,
    dir_block_start: u32,
    parent_inode_num: u32,
    dir_index_count: u16,
    dir_block_offset: u16,
    xattr_index: u32,
    indexes: []const DirIndex,
};

pub fn readExtDirInode(rdr: io.AnyReader) !ExtDirInode {
    const out = ExtDirInode{
        .hard_links = rdr.readInt(u32, std.builtin.Endian.little),
        .dir_table_size = rdr.readInt(u32, std.builtin.Endian.little),
        .dir_block_start = rdr.readInt(u32, std.builtin.Endian.little),
        .parent_inode_num = rdr.readInt(u32, std.builtin.Endian.little),
        .dir_index_count = rdr.readInt(u16, std.builtin.Endian.little),
        .dir_block_offset = rdr.readInt(u16, std.builtin.Endian.little),
        .xattr_index = rdr.readInt(u32, std.builtin.Endian.little),
        .indexes = undefined,
    };
    out.indexes = []const DirIndex{undefined} ** out.dir_index_count;
    const i: u16 = 0;
    while (i < out.dir_index_count) : (i += 1) {
        out.indexes[i] = try readDirIndex(rdr);
    }
    return out;
}

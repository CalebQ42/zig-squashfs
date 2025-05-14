const std = @import("std");
const io = std.io;

pub const DirInode = packed struct {
    dir_block_start: u32,
    hard_links: u32,
    dir_table_size: u16,
    dir_block_offset: u16,
    parent_inode_num: u32,

    pub fn init(rdr: io.AnyReader) !DirInode {
        return try rdr.readStruct(DirInode);
    }
};

pub const DirIndex = struct {
    dir_header_offset: u32,
    dir_table_offset: u32,
    name_size: u32,
    name: []u8,

    pub fn init(rdr: io.AnyReader, alloc: std.mem.Allocator) !DirIndex {
        var out = DirIndex{
            .dir_header_offset = try rdr.readInt(u32, std.builtin.Endian.little),
            .dir_table_offset = try rdr.readInt(u32, std.builtin.Endian.little),
            .name_size = try rdr.readInt(u32, std.builtin.Endian.little),
            .name = undefined,
        };
        out.name = try alloc.alloc(u8, out.name_size);
        _ = try rdr.readAll(out.name);
        return out;
    }
};

pub const ExtDirInode = struct {
    hard_links: u32,
    dir_table_size: u32,
    dir_block_start: u32,
    parent_inode_num: u32,
    dir_index_count: u16,
    dir_block_offset: u16,
    xattr_index: u32,
    indexes: []DirIndex,

    pub fn init(rdr: io.AnyReader, alloc: std.mem.Allocator) !ExtDirInode {
        var out = ExtDirInode{
            .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
            .dir_table_size = try rdr.readInt(u32, std.builtin.Endian.little),
            .dir_block_start = try rdr.readInt(u32, std.builtin.Endian.little),
            .parent_inode_num = try rdr.readInt(u32, std.builtin.Endian.little),
            .dir_index_count = try rdr.readInt(u16, std.builtin.Endian.little),
            .dir_block_offset = try rdr.readInt(u16, std.builtin.Endian.little),
            .xattr_index = try rdr.readInt(u32, std.builtin.Endian.little),
            .indexes = undefined,
        };
        out.indexes = try alloc.alloc(DirIndex, out.dir_index_count);
        var i: u16 = 0;
        while (i < out.dir_index_count) : (i += 1) {
            out.indexes[i] = try .init(rdr, alloc);
        }
        return out;
    }
};

const std = @import("std");

const DirHeader = packed struct {
    count: u32,
    inode_block_start: u32,
    inode_num: u32,
};

const RawDirEntry = struct {
    inode_offset: u16,
    inode_num_difference: i16,
    inode_type: u16,
    name_size: u16,
    name: []u8,

    fn init(rdr: std.io.AnyReader, alloc: std.mem.Allocator) !DirEntry {
        var out: DirEntry = .{
            .inode_offset = try rdr.readInt(u16, std.builtin.Endian.little),
            .inode_num_difference = try rdr.readInt(i16, std.builtin.Endian.little),
            .inode_type = try rdr.readInt(u16, std.builtin.Endian.little),
            .name_size = try rdr.readInt(u16, std.builtin.Endian.little),
            .name = undefined,
        };
        out.name = try alloc.alloc(u8, out.name_size);
        _ = try rdr.readAll(out.name);
        return out;
    }
};

pub const DirEntry = struct {
    inode_offset: u16,
    inode_block_start: u32,
    inode_num: u32,
    name: []u8,

    fn init(raw: RawDirEntry, hdr: DirHeader) DirEntry {
        return .{
            .inode_offset = raw.inode_offset,
            .inode_block_start = hdr.inode_block_start,
            .inode_num = hdr.inode_num - raw.inode_num_difference,
            .name = raw.name,
        };
    }
};


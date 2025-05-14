const std = @import("std");
const io = std.io;

pub const SymlinkInode = struct {
    hard_links: u32,
    target_size: u32,
    path: []u8,
};

pub fn readSymlinkInode(rdr: io.AnyReader, alloc: std.mem.Allocator) !SymlinkInode {
    var out = SymlinkInode{
        .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
        .target_size = try rdr.readInt(u32, std.builtin.Endian.little),
        .path = undefined,
    };
    out.path = try alloc.alloc(u8, out.target_size + 1);
    _ = try rdr.readAll(out.path);
    return out;
}

pub const ExtSymlinkInode = struct {
    hard_links: u32,
    target_size: u32,
    path: []u8,
    xattr_index: u32,
};

pub fn readExtSymlinkInode(rdr: io.AnyReader, alloc: std.mem.Allocator) !ExtSymlinkInode {
    var out = ExtSymlinkInode{
        .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
        .target_size = try rdr.readInt(u32, std.builtin.Endian.little),
        .path = undefined,
        .xattr_index = undefined,
    };
    out.path = try alloc.alloc(u8, out.target_size + 1);
    _ = try rdr.readAll(out.path);
    out.xattr_index = try rdr.readInt(u32, std.builtin.Endian.little);
    return out;
}

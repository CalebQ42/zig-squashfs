const std = @import("std");
const io = std.io;

pub const SymlinkInode = struct {
    hard_links: u32,
    target_size: u32,
    path: []const u8,
};

pub fn readSymlinkInode(rdr: io.AnyReader) !SymlinkInode {
    const out = SymlinkInode{
        .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
        .target_size = try rdr.readInt(u32, std.builtin.Endian.little),
        .path = undefined,
    };
    out.path = (try rdr.readBoundedBytes(out.target_size + 1)).constSlice();
    return out;
}

pub const ExtSymlinkInode = struct {
    hard_links: u32,
    target_size: u32,
    path: []const u8,
    xattr_index: u32,
};

pub fn readExtSymlinkInode(rdr: io.AnyReader) !SymlinkInode {
    const out = ExtSymlinkInode{
        .hard_links = try rdr.readInt(u32, std.builtin.Endian.little),
        .target_size = try rdr.readInt(u32, std.builtin.Endian.little),
        .path = undefined,
        .xattr_index = undefined,
    };
    out.path = (try rdr.readBoundedBytes(out.target_size + 1)).constSlice();
    out.xattr_index = try rdr.readInt(u32, std.builtin.Endian.little);
    return out;
}

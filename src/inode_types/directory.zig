const mem = @import("std").mem;

pub const Directory = packed struct {
    block: u32,
    hard_links: u32,
    size: u16,
    offset: u16,
    parent_num: u32,
    pub fn read(reader: anytype) !Directory {
        var out: Directory = undefined;
        _ = try reader.readAll(@alignCast(mem.asBytes(&out)));
        return out;
    }
};

pub const ExtDirectory = packed struct {
    hard_links: u32,
    size: u32,
    block: u32,
    parent_num: u32,
    idx_count: u16,
    offset: u16,
    xattr_idx: u32,
    pub fn read(reader: anytype) !ExtDirectory {
        var out: ExtDirectory = undefined;
        _ = try reader.readAll(@alignCast(mem.asBytes(&out)));
        return out;
    }
};

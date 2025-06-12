const std = @import("std");

pub const Dir = packed struct {
    block: u32,
    hard_links: u32,
    size: u32,
    offset: u32,
    // parent_num: u32,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtDir = packed struct {
    hard_links: u32,
    size: u32,
    block: u32,
    parent_num: u32,
    index_count: u16,
    offset: u16,
    xattr_idx: u32,
    // index: []DirIndex,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

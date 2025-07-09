const std = @import("std");

pub const Dir = packed struct {
    block: u32,
    hard_link: u32,
    size: u16,
    offset: u16,
    parent_num: u32,

    pub fn init(rdr: anytype) !Dir {
        const out: Dir = undefined;
        _ = rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtDir = packed struct {
    hard_link: u32,
    size: u32,
    block: u32,
    parent_num: u32,
    idx_count: u16,
    offset: u16,
    xattr_idx: u32,

    pub fn init(rdr: anytype) !ExtDir {
        const out: ExtDir = undefined;
        _ = rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

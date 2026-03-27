const Reader = @import("std").Io.Reader;

pub const Dir = packed struct {
    block_start: u32,
    hard_links: u32,
    size: u16,
    block_offset: u16,
    parent_num: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

pub const ExtDir = packed struct {
    hard_links: u32,
    size: u32,
    block_start: u32,
    parent_num: u32,
    idx_count: u16,
    block_offset: u16,
    xattr_idx: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

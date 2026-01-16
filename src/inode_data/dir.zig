const Reader = @import("std").Io.Reader;

pub const Dir = packed struct {
    block_start: u32,
    hard_links: u32,
    size: u16,
    block_offset: u32,
    parent_num: u32,

    pub fn read(rdr: *Reader) !Dir {
        var d: Dir = undefined;
        try rdr.readSliceEndian(Dir, @ptrCast(&d), .little);
        return d;
    }
};

pub const ExtDir = packed struct {
    hard_links: u32,
    size: u32,
    block_start: u32,
    parent_num: u32,
    idx_count: u16,
    block_offset: u16,
    xattr_id: u32,
    // index: []DirIndex

    pub fn read(rdr: *Reader) !ExtDir {
        var d: ExtDir = undefined;
        try rdr.readSliceEndian(Dir, @ptrCast(&d), .little);
        return d;
    }
};

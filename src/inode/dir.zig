const io = @import("std").io;

pub const DirInode = packed struct {
    block_start: u32,
    hard_links: u32,
    /// Note: size is 3 larger then the actual size, due to "." and ".."
    size: u16,
    offset: u16,
    parent_num: u32,

    pub fn init(rdr: io.AnyReader) !DirInode {
        return rdr.readStruct(DirInode);
    }
};

const DirIndex = struct {
    offset: u32,
    block_start: u32,
    name_size: u32,
    name: []const u8,
};

pub const ExtDirInode = packed struct {
    hard_links: u32,
    /// Note: size is 3 larger then the actual size, due to "." and ".."
    size: u32,
    block_start: u32,
    parent_num: u32,
    index_count: u16,
    offset: u16,
    xattr_inx: u32,
    // TODO: possibly also read dir indexes. Maybe relagate to function...

    pub fn init(rdr: io.AnyReader) !ExtDirInode {
        return rdr.readStruct(ExtDirInode);
    }
};

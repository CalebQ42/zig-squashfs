pub const DirInode = packed struct {
    dir_block_start: u32,
    hard_links: u32,
    dir_table_size: u16,
    dir_block_offset: u16,
    parent_inode_num: u32,
};

pub const DirIndexStart = packed struct {
    dir_header_offset: u32,
    dir_table_offset: u32,
    name_size: u32,
};

pub const DirIndex = struct {
    start: DirIndexStart,
    name: []const u8,
};

pub const ExtDirInodeStart = packed struct {
    hard_links: u32,
    dir_table_size: u32,
    dir_block_start: u32,
    parent_inode_num: u32,
    dir_index_count: u16,
    dir_block_offset: u16,
    xattr_index: u32,
};

pub const ExtDirInode = struct {
    start: ExtDirInodeStart,
    indexes: []const u8,
};

pub const FileInodeStart = packed struct {
    start: u32,
    frag_index: u32,
    frag_block_offset: u32,
    size: u32,
};

pub const FileInode = struct {
    start: FileInodeStart,
    block_sizes: []const u32,
};

pub const ExtFileInodeStart = packed struct {
    start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_index: u32,
    frag_block_offset: u32,
    xattr_index: u32,
};

pub const ExtFileInode = struct {
    start: ExtFileInodeStart,
    block_sizes: []const u32,
};

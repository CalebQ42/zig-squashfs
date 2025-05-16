pub const InodeRef = packed struct {
    offset: u16,
    block_start: u32,
    _: u16,
};

pub const InodeType = enum(u16) {
    dir,
    file,
    sym,
    block,
    char,
    fifo,
    sock,
    ext_dir,
    ext_file,
    ext_sym,
    ext_block,
    ext_char,
    ext_fifo,
    ext_sock,
};

pub const InodeHeader = packed struct {
    inode_type: InodeType,
    perm: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Inode = struct {
    header: InodeHeader,
    data: void, //TODO
};

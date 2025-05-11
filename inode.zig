pub const InodeRef = packed struct {
    _: u16,
    block_start: u32,
    offset: u16,
};

const InodeType = enum(u16) {
    dir = 1,
    file,
    symlink,
    block_device,
    char_device,
    fifo,
    socket,
    ext_dir,
    ext_file,
    ext_symlink,
    ext_block_device,
    ext_char_device,
    ext_fifo,
    ext_socket,
};

pub const InodeHeader = packed struct {
    inode_type: InodeType,
    perm: u16,
    uid_index: u16,
    gid_index: u16,
    mod_time: u32,
    inode_num: u32,
};

const itypes = @import("inode_types.zig");

const InodeData = union(enum) {
    dir: itypes.DirInode,
    file: itypes.FileInode,
    symlink: itypes.SymlinkInode,
    block_device: itypes.DeviceInode,
    char_device: itypes.DeviceInode,
    fifo: itypes.FifoInode,
    socket: itypes.FifoInode,
    ext_dir: itypes.ExtDirInode,
    ext_file: itypes.ExtFileInode,
    ext_symlink: itypes.ExtSymlinkInode,
    ext_block_device: itypes.ExtDeviceInode,
    ext_char_device: itypes.ExtDeviceInode,
    ext_fifo: itypes.ExtFifoInode,
    ext_socket: itypes.ExtFifoInode,
};

const Inode = @This();

pub const InodeRef = packed struct {
    offset: u16,
    block: u48,
};

pub const Types = enum(u16) {
    directory = 1,
    file,
    symlink,
    block_dev,
    char_dev,
    fifo,
    socket,
    ext_directory,
    ext_file,
    ext_symlink,
    ext_block_dev,
    ext_char_dev,
    ext_fifo,
    ext_socket,
};

pub const Data = union(enum) {
    directory: @import("inode_types/dir.zig"),
    file: @import("inode_types/file.zig"),
    symlink: @import("inode_types/sym.zig"),
    block_dev,
    char_dev: @import("inode_types/dev.zig"),
    fifo,
    socket: @import("inode_types/ext_ipc.zig"),
    ext_directory: @import("inode_types/ext_dir.zig"),
    ext_file: @import("inode_types/ext_file.zig"),
    ext_symlink: @import("inode_types/ext_sym.zig"),
    ext_block_dev,
    ext_char_dev: @import("inode_types/ext_dev.zig"),
    ext_fifo,
    ext_socket: @import("inode_types/ext_ipc.zig"),
};

pub const Header = packed struct {
    inode_type: Types,
    perm: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

hdr: Header,
data: Data,

pub fn init() !Inode {}

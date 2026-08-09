const std = @import("std");
const Io = std.Io;

const Inode = @This();

header: Header,
data: Data,

// Types

pub const Reference = packed struct(u64) {
    _: u16,
    block: u32,
    offset: u16,
};

pub const Type = enum(u16) {
    dir,
    file,
    symlink,
    block_dev,
    char_dev,
    fifo,
    socket,
    ext_dir,
    ext_file,
    ext_symlink,
    ext_block_dev,
    ext_char_dev,
    ext_fifo,
    ext_socket,
};

pub const Header = extern struct {
    type: Type, // TODO: enum
    permission: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    inode_num: u32,
};

pub const Data = union(Type) {
    dir: Dir,
    file: File,
    symlink: Symlink,
    block_dev: Dev,
    char_dev: Dev,
    fifo: Fifo,
    socket: Fifo,
    ext_dir: ExtDir,
    ext_file: ExtFile,
    ext_symlink: ExtSymlink,
    ext_block_dev: ExtDev,
    ext_char_dev: ExtDev,
    ext_fifo: ExtFifo,
    ext_socket: ExtFifo,
};

// Inode data types

pub const Dir = extern struct {
    block: u32,
    hard_links: u32,
    size: u16,
    offset: u16,
    parent_inode_num: u32,
};
pub const ExtDir = extern struct {
    hard_links: u32,
    size: u32,
    block: u32,
    parent_inode_num: u32,
    idx_count: u16,
    offset: u16,
    xattr_idx: u32,
};

pub const File = struct {};
pub const ExtFile = struct {};

pub const Symlink = struct {};
pub const ExtSymlink = struct {};

pub const Dev = extern struct {};
pub const ExtDev = extern struct {};

pub const Fifo = extern struct {};
pub const ExtFifo = extern struct {};

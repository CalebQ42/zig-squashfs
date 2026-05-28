const std = @import("std");

const Inode = @This();

hdr: Header,
data: Data,

// Types

pub const Ref = packed struct(u64) {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const Enum = enum(u16) {
    dir = 1,
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
    type: Enum,
    permission: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Data = union(Enum) {
    dir: ,
    file: ,
    symlink: ,
    block_dev: ,
    char_dev: ,
    fifo: ,
    socket: ,
    ext_dir: ,
    ext_file: ,
    ext_symlink: ,
    ext_block_dev: ,
    ext_char_dev: ,
    ext_fifo: ,
    ext_socket: ,
};

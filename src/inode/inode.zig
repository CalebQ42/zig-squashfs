const std = @import("std");
const io = std.io;

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

const dir = @import("dir.zig");
const file = @import("file.zig");
const sym = @import("sym.zig");
const misc = @import("misc.zig");

pub const InodeData = union(enum) {
    dir: dir.DirInode,
    file: file.FileInode,
    sym: sym.SymInode,
    block: misc.DeviceInode,
    char: misc.DeviceInode,
    fifo: misc.IPCInode,
    sock: misc.IPCInode,
    ext_dir: dir.ExtDirInode,
    ext_file: file.ExtFileInode,
    ext_sym: sym.ExtSymInode,
    ext_block: misc.ExtDeviceInode,
    ext_char: misc.ExtDeviceInode,
    ext_fifo: misc.ExtIPCInode,
    ext_sock: misc.ExtIPCInode,
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
    data: InodeData, //TODO

    pub fn init(rdr: io.AnyReader) !Inode {}
};

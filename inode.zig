pub const InodeRef = packed struct {
    _: u16,
    block_start: u32,
    offset: u16,
};

pub const InodeType = enum(u16) {
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

pub const InodeData = union(enum) {
    dir: dir.DirInode,
    file: file.FileInode,
    symlink: sym.SymlinkInode,
    block_device: misc.DeviceInode,
    char_device: misc.DeviceInode,
    fifo: misc.IPCInode,
    socket: misc.IPCInode,
    ext_dir: dir.ExtDirInode,
    ext_file: file.ExtFileInode,
    ext_symlink: sym.ExtSymlinkInode,
    ext_block_device: misc.ExtDeviceInode,
    ext_char_device: misc.ExtDeviceInode,
    ext_fifo: misc.IPCInode,
    ext_socket: misc.IPCInode,
};

const dir = @import("inode_types/dir.zig");
const file = @import("inode_types/file.zig");
const sym = @import("inode_types/sym.zig");
const misc = @import("inode_types/misc.zig");

const Inode = struct {
    header: InodeHeader,
    data: InodeData,
};

const io = @import("std").io;

pub fn readInode(rdr: io.AnyReader, block_size: u64) !Inode {
    const hdr = try rdr.readStruct(InodeHeader);
    const data: InodeData = undefined;
    switch (hdr.inode_type) {
        .dir => data = .{
            .dir = dir.readDirInode(rdr),
        },
        .ext_dir => data = .{
            .ext_dir = try dir.readExtDirInode(rdr),
        },
        .file => data = .{
            .file = try file.readFileInode(rdr, block_size),
        },
        .ext_file => data = .{
            .ext_file = try file.readExtFileInode(rdr, block_size),
        },
        .symlink => data = .{
            .block_device = try misc.readSymlinkInode(rdr),
        },
        .ext_symlink => data = .{
            .ext_symlink = try sym.readExtSymlinkInode(rdr),
        },
    }
    return Inode{
        .header = hdr,
        .data = data,
    };
}

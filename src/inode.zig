//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;

const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");

const Inode = @This();

hdr: Header,
data: Data,

pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u16) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    return .{
        .hdr = hdr,
        .data = switch (hdr.inode_type) {
            .dir => .{ .dir = .read(rdr) },
            .file => .{ .file = .read(alloc, rdr, block_size) },
            .symlink => .{ .symlink = .read(alloc, rdr) },
            .block_dev => .{ .block_dev = .read(rdr) },
            .char_dev => .{ .char_dev = .read(rdr) },
            .fifo => .{ .fifo = .read(rdr) },
            .socket => .{ .socket = .read(rdr) },
            .ext_dir => .{ .ext_dir = .read(rdr) },
            .ext_file => .{ .ext_file = .read(alloc, rdr, block_size) },
            .ext_symlink => .{ .ext_symlink = .read(alloc, rdr) },
            .ext_block_dev => .{ .ext_block_dev = .read(rdr) },
            .ext_char_dev => .{ .ext_char_dev = .read(rdr) },
            .ext_fifo => .{ .ext_fifo = .read(rdr) },
            .ext_socket => .{ .ext_socket = .read(rdr) },
        },
    };
}

// Types

pub const Ref = packed struct(u64) {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const Type = enum(u16) {
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

pub const Data = union(Type) {
    dir: dir.Dir,
    file: file.File,
    symlink: misc.Symlink,
    block_dev: misc.Dev,
    char_dev: misc.Dev,
    fifo: misc.IPC,
    socket: misc.IPC,
    ext_dir: dir.ExtDir,
    ext_file: file.ExtFile,
    ext_symlink: misc.ExtSymlink,
    ext_block_dev: misc.ExtDev,
    ext_char_dev: misc.ExtDev,
    ext_fifo: misc.ExtIPC,
    ext_socket: misc.ExtIPC,
};

pub const Header = packed struct {
    inode_type: Type,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

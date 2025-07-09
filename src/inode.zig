const std = @import("std");

const dir = @import("inode/dir.zig");
const file = @import("inode/file.zig");
const misc = @import("inode/misc.zig");

pub const Ref = packed struct {
    offset: u16,
    block: u32,
    _: u16,
};

const Type = enum(u16) {
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

const Header = packed struct {
    type: Type,
    perm: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

const Data = union(enum) {
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

const Self = @This();

hdr: Header,
data: Data,

pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !Self {
    std.debug.assert(std.meta.hasFn(@TypeOf(rdr), "read"));
    var hdr: Header = undefined;
    _ = try rdr.read(std.mem.asBytes(&hdr));
    const data = switch (hdr.type) {
        .dir => .{ .dir = .init(rdr) },
        .file => .{ .file = .init(rdr, alloc, block_size) },
        .symlink => .{ .symlink = .init(rdr, alloc) },
        .block_dev => .{ .block_dev = .init(rdr) },
        .char_dev => .{ .char_dev = .init(rdr) },
        .fifo => .{ .fifo = .init(rdr) },
        .socket => .{ .socket = .init(rdr) },
        .ext_dir => .{ .ext_dir = .init(rdr) },
        .ext_file => .{ .ext_file = .init(rdr, alloc, block_size) },
        .ext_symlink => .{ .ext_symlink = .init(rdr, alloc) },
        .ext_block_dev => .{ .ext_block_dev = .init(rdr) },
        .ext_char_dev => .{ .ext_char_dev = .init(rdr) },
        .ext_fifo => .{ .ext_fifo = .init(rdr) },
        .ext_socket => .{ .ext_socket = .init(rdr) },
    };
    return .{
        .hdr = hdr,
        .data = data,
    };
}

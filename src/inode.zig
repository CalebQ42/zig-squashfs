const std = @import("std");

pub const Ref = packed struct {
    _: u16,
    block: u32,
    offset: u16,
};

pub const Type = enum(u16) {
    dir = 1,
    file,
    sym,
    block_dev,
    char_dev,
    fifo,
    socket,
    ext_dir,
    ext_file,
    ext_sym,
    ext_block_dev,
    ext_char_dev,
    ext_fifo,
    ext_socket,
};

pub const Header = packed struct {
    inode_type: Type,
    perm: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

const dir = @import("inode_types/dir.zig");
const fil = @import("inode_types/file.zig");
const sym = @import("inode_types/sym.zig");
const misc = @import("inode_types/misc.zig");

pub const Data = union(enum) {
    dir: dir.Dir,
    file: fil.File,
    sym: sym.Sym,
    block_dev: misc.Dev,
    char_dev: misc.Dev,
    fifo: misc.IPC,
    socket: misc.IPC,
    ext_dir: dir.ExtDir,
    ext_file: fil.ExtFile,
    ext_sym: sym.ExtSym,
    ext_block_dev: misc.ExtDev,
    ext_char_dev: misc.ExtDev,
    ext_fifo: misc.ExtIPC,
    ext_socket: misc.ExtIPC,
};

const Inode = @This();

header: Header,
data: Data,

pub fn init(rdr: anytype, alloc: std.mem.Allocator, block_size: u32) !Inode {
    comptime std.debug.assert(std.meta.hasFn(rdr, "read"));
    const hdr: Header = undefined;
    _ = try rdr.read(std.mem.asBytes(&hdr));
    return .{
        .header = hdr,
        .data = switch (hdr.inode_type) {
            .dir => .{ .dir = .init(rdr) },
            .file => .{ .file = .init(rdr, alloc, block_size) },
            .sym => .{ .sym = .init(rdr, alloc) },
            .block_dev => .{ .block_dev = .init(rdr) },
            .char_dev => .{ .char_dev = .init(rdr) },
            .fifo => .{ .fifo = .init(rdr) },
            .socket => .{ .socket = .init(rdr) },
            .ext_dir => .{ .ext_dir = .init(rdr) },
            .ext_file => .{ .ext_file = .init(rdr, alloc, block_size) },
            .ext_sym => .{ .ext_sym = .init(rdr, alloc) },
            .ext_block_dev => .{ .ext_block_dev = .init(rdr) },
            .ext_char_dev => .{ .ext_char_dev = .init(rdr) },
            .ext_fifo => .{ .ext_fifo = .init(rdr) },
            .ext_socket => .{ .ext_socket = .init(rdr) },
        },
    };
}

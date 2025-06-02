pub const Ref = packed struct {
    offset: u16,
    block: u32,
    _: u16 = 0,
};

pub const DataBlockSize = packed struct {
    size: u24,
    not_compressed: bool,
    _: u7,
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

pub const Header = packed struct {
    inode_type: Types,
    perm: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

const dir = @import("inode_types/directory.zig");
const fil = @import("inode_types/file.zig");
const sym = @import("inode_types/symlink.zig");
const misc = @import("inode_types/misc.zig");

pub const Data = union(enum) {
    directory: dir.Directory,
    file: fil.File,
    symlink: sym.Symlink,
    block_dev: misc.Device,
    char_dev: misc.Device,
    fifo: misc.IPC,
    socket: misc.IPC,
    ext_directory: dir.ExtDirectory,
    ext_file: fil.ExtFile,
    ext_symlink: sym.ExtSymlink,
    ext_block_dev: misc.ExtDevice,
    ext_char_dev: misc.ExtDevice,
    ext_fifo: misc.ExtIPC,
    ext_socket: misc.ExtIPC,
};

const std = @import("std");

const Inode = @This();

alloc: std.mem.Allocator,
hdr: Header,
data: Data,

pub fn read(alloc: std.mem.Allocator, block_size: u32, reader: anytype) !Inode {
    // comptime std.debug.assert(std.meta.hasFn(@TypeOf(reader), "readAll"));
    std.debug.print("{}\n", .{@TypeOf(reader)});
    var out: Inode = undefined;
    _ = try reader.readAll(std.mem.asBytes(&out.hdr));
    out.alloc = alloc;
    out.data = switch (out.hdr.inode_type) {
        .directory => .{ .directory = try .read(reader) },
        .file => .{ .file = try .read(alloc, block_size, reader) },
        .symlink => .{ .symlink = try .read(alloc, reader) },
        .block_dev => .{ .block_dev = try .read(reader) },
        .char_dev => .{ .char_dev = try .read(reader) },
        .fifo => .{ .fifo = try .read(reader) },
        .socket => .{ .socket = try .read(reader) },
        .ext_directory => .{ .ext_directory = try .read(reader) },
        .ext_file => .{ .ext_file = try .read(alloc, block_size, reader) },
        .ext_symlink => .{ .ext_symlink = try .read(alloc, reader) },
        .ext_block_dev => .{ .ext_block_dev = try .read(reader) },
        .ext_char_dev => .{ .ext_char_dev = try .read(reader) },
        .ext_fifo => .{ .ext_fifo = try .read(reader) },
        .ext_socket => .{ .ext_socket = try .read(reader) },
    };
    return out;
}
pub fn deinit(self: Inode) void {
    switch (self.data) {
        .file => |f| f.deinit(self.alloc),
        .symlink => |s| s.deinit(self.alloc),
        .ext_file => |f| f.deinit(self.alloc),
        .ext_symlink => |s| s.deinit(self.alloc),
        else => {},
    }
}

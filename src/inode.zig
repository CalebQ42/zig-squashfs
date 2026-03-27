const std = @import("std");
const Reader = std.Io.Reader;

const Dir = @import("inode/dir.zig");
const File = @import("inode/file.zig");
const Misc = @import("inode/misc.zig");
const Sym = @import("inode/sym.zig");

const Inode = @This();

hdr: Header,
data: Data,

pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    return .{
        .hdr = hdr,
        .data = switch (hdr.inode_type) {
            .dir => .{ .dir = .read(rdr) },
            .file => .{ .file = .read(alloc, rdr, block_size) },
            .symlink => .{ .symlink = .read(alloc, rdr) },
            .block => .{ .block = .read(rdr) },
            .char => .{ .char = .read(rdr) },
            .fifo => .{ .fifo = .read(rdr) },
            .sock => .{ .sock = .read(rdr) },
            .ext_dir => .{ .ext_dir = .read(rdr) },
            .ext_file => .{ .ext_file = .read(alloc, rdr, block_size) },
            .ext_symlink => .{ .ext_symlink = .read(alloc, rdr) },
            .ext_block => .{ .ext_block = .read(rdr) },
            .ext_char => .{ .ext_char = .read(rdr) },
            .ext_fifo => .{ .ext_fifo = .read(rdr) },
            .ext_sock => .{ .ext_sock = .read(rdr) },
        },
    };
}
pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |f| alloc.free(f.block_sizes),
        .ext_file => |f| alloc.free(f.block_sizes),
        .symlink => |s| alloc.free(s.target),
        .ext_symlink => |s| alloc.free(s.target),
        else => {},
    }
}

// Types

pub const Ref = packed struct {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const Type = enum(u16) {
    dir = 1,
    file,
    symlink,
    block,
    char,
    fifo,
    sock,
    ext_dir,
    ext_file,
    ext_symlink,
    ext_block,
    ext_char,
    ext_fifo,
    ext_sock,
};

const Header = packed struct {
    inode_type: Type,
    permission: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Data = union(Type) {
    dir: Dir.Dir,
    file: File.File,
    symlink: Sym.Symlink,
    block: Misc.Device,
    char: Misc.Device,
    fifo: Misc.Ipc,
    sock: Misc.Ipc,
    ext_dir: Dir.ExtDir,
    ext_file: File.ExtFile,
    ext_symlink: Sym.ExtSymlink,
    ext_block: Misc.ExtDevice,
    ext_char: Misc.ExtDevice,
    ext_fifo: Misc.ExtIpc,
    ext_sock: Misc.ExtIpc,
};

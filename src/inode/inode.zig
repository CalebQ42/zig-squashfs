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
    alloc: std.mem.Allocator,
    header: InodeHeader,
    data: InodeData,

    pub fn init(alloc: std.mem.Allocator, rdr: io.AnyReader, block_size: u32) !Inode {
        const hdr = try rdr.readStruct(InodeHeader);
        const data: InodeData = switch (hdr.inode_type) {
            .dir => .{ .dir = try .init(rdr) },
            .file => .{ .file = try .init(alloc, rdr, block_size) },
            .sym => .{ .sym = try .init(alloc, rdr) },
            .block => .{ .block = try .init(rdr) },
            .char => .{ .char = try .init(rdr) },
            .fifo => .{ .fifo = try .init(rdr) },
            .sock => .{ .sock = try .init(rdr) },
            .ext_dir => .{ .ext_dir = try .init(rdr) },
            .ext_file => .{ .ext_file = try .init(alloc, rdr, block_size) },
            .ext_sym => .{ .ext_sym = try .init(alloc, rdr) },
            .ext_block => .{ .ext_block = try .init(rdr) },
            .ext_char => .{ .ext_char = try .init(rdr) },
            .ext_fifo => .{ .ext_fifo = try .init(rdr) },
            .ext_sock => .{ .ext_sock = try .init(rdr) },
        };
        return .{
            .alloc = alloc,
            .header = hdr,
            .data = data,
        };
    }
    pub fn deinit(self: Inode) void {
        switch (self.data) {
            .file => |d| d.deinit(self.alloc),
            .sym => |d| d.deinit(self.alloc),
            .ext_file => |d| d.deinit(self.alloc),
            .ext_sym => |d| d.deinit(self.alloc),
            else => {},
        }
    }
};

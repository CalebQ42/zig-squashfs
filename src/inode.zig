const std = @import("std");
const Io = std.Io;

const util = @import("utils/util.zig");

const MetadataReader = @import("utils/meta.zig");
const Super = @import("archive.zig").Super;

const Inode = @This();

header: Header,
data: Data,

pub fn fromRef(alloc: std.mem.Allocator, data: []u8, ref: Reference, super: Super) !Inode {
    var meta: MetadataReader = .init(alloc, data[super.inode_table_start + ref.start ..], super.decomp_fn);
    try meta.interface.discardAll(ref.offset);

    return read(alloc, &meta.interface, super.block_size);
}
pub fn read(alloc: std.mem.Allocator, rdr: *Io.Reader, block_size: u32) !Inode {
    const hdr = try util.readValueRdr(Header, rdr);

    return .{
        .header = hdr,
        .data = switch (hdr.type) {
            .dir => .{ .dir = try .read(rdr) },
            .file => .{ .file = try .read(rdr, alloc, block_size) },
            .symlink => .{ .symlink = try .read(rdr, alloc) },
            .block_dev => .{ .block_dev = try .read(rdr) },
            .char_dev => .{ .char_dev = try .read(rdr) },
            .fifo => .{ .fifo = try .read(rdr) },
            .socket => .{ .socket = try .read(rdr) },
            .ext_dir => .{ .ext_dir = try .read(rdr) },
            .ext_file => .{ .ext_file = try .read(rdr, alloc, block_size) },
            .ext_symlink => .{ .ext_symlink = try .read(rdr, alloc) },
            .ext_block_dev => .{ .ext_block_dev = try .read(rdr) },
            .ext_char_dev => .{ .ext_char_dev = try .read(rdr) },
            .ext_fifo => .{ .ext_fifo = try .read(rdr) },
            .ext_socket => .{ .ext_socket = try .read(rdr) },
        },
    };
}
pub fn copy(self: Inode, alloc: std.mem.Allocator) !Inode {
    var new_inode = self;

    switch (new_inode.data) {
        .file => |*f| f.blocks = try alloc.dupe(BlockSize, f.blocks),
        .ext_file => |*f| f.blocks = try alloc.dupe(BlockSize, f.blocks),
        .symlink => |*f| f.target = try alloc.dupe(u8, f.target),
        .ext_symlink => |*f| f.target = try alloc.dupe(u8, f.target),
        else => {},
    }

    return new_inode;
}
pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |f| alloc.free(f.blocks),
        .ext_file => |f| alloc.free(f.blocks),
        .symlink => |s| alloc.free(s.target),
        .ext_symlink => |s| alloc.free(s.target),
        else => {},
    }
}

// Types

pub const Reference = packed struct(u64) {
    offset: u16,
    start: u32,
    _: u16,
};

pub const BlockSize = packed struct(u32) {
    size: u23,
    uncompressed: bool,
    _: u8,
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
    type: Type,
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
    ext_symlink: Symlink,
    ext_block_dev: ExtDev,
    ext_char_dev: ExtDev,
    ext_fifo: ExtFifo,
    ext_socket: ExtFifo,
};

// Inode data types

pub const Dir = extern struct {
    start: u32,
    hard_links: u32,
    size: u16,
    offset: u16,
    parent_inode_num: u32,

    pub fn read(rdr: *Io.Reader) !Dir {
        return util.readValueRdr(Dir, rdr);
    }
};
pub const ExtDir = extern struct {
    hard_links: u32,
    size: u32,
    start: u32,
    parent_inode_num: u32,
    idx_count: u16,
    offset: u16,
    xattr_idx: u32,

    pub fn read(rdr: *Io.Reader) !ExtDir {
        return util.readValueRdr(ExtDir, rdr);
    }
};

pub const File = struct {
    start: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    blocks: []BlockSize,

    pub fn read(rdr: *Io.Reader, alloc: std.mem.Allocator, block_size: u32) !File {
        var raw: [16]u8 = undefined;
        try rdr.readSliceAll(&raw);

        const frag_idx = std.mem.readInt(u32, raw[4..8], .little);
        const size = std.mem.readInt(u32, raw[12..16], .little);

        var num = size / block_size;
        if (frag_idx == 0xFFFFFFFF and size % block_size > 0)
            num += 1;

        const blocks = try alloc.alloc(BlockSize, num);
        try rdr.readSliceEndian(BlockSize, blocks, .little);

        return .{
            .start = std.mem.readInt(u32, raw[0..4], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, raw[8..12], .little),
            .size = size,
            .blocks = blocks,
        };
    }
};
pub const ExtFile = struct {
    start: u64,
    size: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    blocks: []BlockSize,

    pub fn read(rdr: *Io.Reader, alloc: std.mem.Allocator, block_size: u32) !ExtFile {
        var raw: [40]u8 = undefined;
        try rdr.readSliceAll(&raw);

        const frag_idx = std.mem.readInt(u32, raw[28..32], .little);
        const size = std.mem.readInt(u64, raw[8..16], .little);

        var num = size / block_size;
        if (frag_idx == 0xFFFFFFFF and size % block_size > 0)
            num += 1;

        const blocks = try alloc.alloc(BlockSize, num);
        try rdr.readSliceEndian(BlockSize, blocks, .little);

        return .{
            .start = std.mem.readInt(u64, raw[0..8], .little),
            .size = size,
            .hard_links = std.mem.readInt(u32, raw[24..28], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, raw[32..36], .little),
            .xattr_idx = std.mem.readInt(u32, raw[36..], .little),
            .blocks = blocks,
        };
    }
};

pub const Symlink = struct {
    hard_links: u32,
    target: []const u8,

    pub fn read(rdr: *Io.Reader, alloc: std.mem.Allocator) !Symlink {
        var raw: [8]u8 = undefined;
        try rdr.readSliceAll(&raw);

        const target = try alloc.alloc(u8, std.mem.readInt(u32, raw[4..], .little));
        errdefer alloc.free(target);

        try rdr.readSliceEndian(u8, target, .little);

        return .{
            .hard_links = std.mem.readInt(u32, raw[0..4], .little),
            .target = target,
        };
    }
};

pub const Dev = extern struct {
    hard_links: u32,
    device: u32,

    pub fn read(rdr: *Io.Reader) !Dev {
        return util.readValueRdr(Dev, rdr);
    }
};
pub const ExtDev = extern struct {
    hard_links: u32,
    device: u32,
    xattr_idx: u32,

    pub fn read(rdr: *Io.Reader) !ExtDev {
        return util.readValue(ExtDev, rdr);
    }
};

pub const Fifo = extern struct {
    hard_links: u32,

    pub fn read(rdr: *Io.Reader) !Fifo {
        return util.readValueRdr(Fifo, rdr);
    }
};
pub const ExtFifo = extern struct {
    hard_links: u32,
    xattr_idx: u32,

    pub fn read(rdr: *Io.Reader) !ExtFifo {
        return util.readValueRdr(ExtFifo, rdr);
    }
};

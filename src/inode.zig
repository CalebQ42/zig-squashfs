const std = @import("std");
const Io = std.Io;

const util = @import("utils/util.zig");

const MetadataReader = @import("utils/meta.zig");
const Super = @import("archive.zig").Super;

const Inode = @This();

header: Header,
data: Data,

pub fn readLocation(alloc: std.mem.Allocator, data: []u8, start: u32, offset: u16, super: Super) !Inode {
    var meta: MetadataReader = .init(alloc, data[super.inode_table_start + start ..], super.decomp_fn);
    try meta.interface.discardAll(offset);

    return read(alloc, &meta.interface, super.block_size);
}
pub fn read(alloc: std.mem.Allocator, rdr: *Io.Reader, block_size: u32) !Inode {
    const hdr = try util.readValueRdr(Header, rdr);

    return .{
        .header = hdr,
        .data = switch (hdr.type) {
            .dir => .{ .dir = try .readBasic(rdr) },
            .ext_dir => .{ .dir = try .readExt(rdr) },
            .file => .{ .file = try .readBasic(rdr, alloc, block_size) },
            .ext_file => .{ .file = try .readExt(rdr, alloc, block_size) },
            .symlink, .ext_symlink => .{ .symlink = try .read(rdr, alloc) },
            .block_dev, .char_dev => .{ .dev = try .readBasic(rdr) },
            .ext_block_dev, .ext_char_dev => .{ .dev = try .readExt(rdr) },
            .fifo, .socket => .{ .fifo = try .readBasic(rdr) },
            .ext_fifo, .ext_socket => .{ .fifo = try .readExt(rdr) },
        },
    };
}
pub fn copy(self: Inode, alloc: std.mem.Allocator) !Inode {
    var new_inode = self;

    switch (new_inode.data) {
        .file => |*f| f.blocks = try alloc.dupe(BlockSize, f.blocks),
        .symlink => |*f| f.target = try alloc.dupe(u8, f.target),
        else => {},
    }

    return new_inode;
}
pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |f| alloc.free(f.blocks),
        .symlink => |s| alloc.free(s.target),
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
    type: Type,
    permission: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    inode_num: u32,
};

pub const Data = union(enum) {
    dir: Dir,
    file: File,
    symlink: Symlink,
    dev: Dev,
    fifo: Fifo,
};

// Inode data types

pub const Dir = struct {
    //RegularDir structure:
    //    start: u32,
    //    hard_links: u32,
    //    size: u16,
    //    offset: u16,
    //    parent_inode_num: u32,
    // ExtDir structure
    //    hard_links: u32,
    //    size: u32,
    //    start: u32,
    //    parent_inode_num: u32,
    //    idx_count: u16,
    //    offset: u16,
    //    xattr_idx: u32,
    //    dir_indexes: []DirIndex,

    hard_links: u32,
    size: u32,
    start: u32,
    offset: u16,
    xattr_idx: ?u32,

    pub fn readBasic(rdr: *Io.Reader) !Dir {
        var raw: [12]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .start = util.readValue(u32, raw[0..4]),
            .hard_links = util.readValue(u32, raw[4..8]),
            .size = util.readValue(u16, raw[8..10]),
            .offset = util.readValue(u16, raw[10..12]),
            .xattr_idx = null,
        };
    }
    pub fn readExt(rdr: *Io.Reader) !Dir {
        var raw: [24]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .hard_links = util.readValue(u32, raw[0..4]),
            .size = util.readValue(u32, raw[4..8]),
            .start = util.readValue(u32, raw[8..12]),
            .offset = util.readValue(u16, raw[18..20]),
            .xattr_idx = util.readValue(u32, raw[20..24]),
        };
    }
};

pub const File = struct {
    //RegularFile structure:
    //    start: u32,
    //    frag_idx: u32,
    //    frag_offset: u32,
    //    size: u32,
    //    block_sizes: []BlockSize,
    //ExtFile structure:
    //    start: u64,
    //    size: u64,
    //    sparse: u64,
    //    hard_links: u32,
    //    frag_idx: u32,
    //    frag_offset: u32,
    //    xattr_idx: u32,
    //    block_sizes: []BlockSize,

    start: u64,
    frag_idx: u32,
    frag_offset: u32,
    size: u64,
    blocks: []BlockSize,
    xattr_idx: ?u32,

    pub fn readBasic(rdr: *Io.Reader, alloc: std.mem.Allocator, block_size: u32) !File {
        var raw: [16]u8 = undefined;
        try rdr.readSliceAll(&raw);

        const frag_idx = util.readValue(u32, raw[4..8]);
        const size = util.readValue(u32, raw[12..16]);

        const block_num = if (frag_idx == 0xFFFFFFFF)
            try std.math.divCeil(usize, size, block_size)
        else
            size / block_size;

        const sizes = try alloc.alloc(BlockSize, block_num);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .start = util.readValue(u32, raw[0..4]),
            .frag_idx = frag_idx,
            .frag_offset = util.readValue(u32, raw[8..12]),
            .size = size,
            .blocks = sizes,
            .xattr_idx = null,
        };
    }
    pub fn readExt(rdr: *Io.Reader, alloc: std.mem.Allocator, block_size: u32) !File {
        var raw: [40]u8 = undefined;
        try rdr.readSliceAll(&raw);

        const frag_idx = util.readValue(u32, raw[28..32]);
        const size = util.readValue(u64, raw[8..16]);

        const block_num = if (frag_idx == 0xFFFFFFFF)
            try std.math.divCeil(usize, size, block_size)
        else
            size / block_size;

        const sizes = try alloc.alloc(BlockSize, block_num);
        try rdr.readSliceEndian(BlockSize, sizes, .little);

        return .{
            .start = util.readValue(u64, raw[0..8]),
            .size = size,
            .frag_idx = frag_idx,
            .frag_offset = util.readValue(u32, raw[32..36]),
            .blocks = sizes,
            .xattr_idx = util.readValue(u32, raw[36..40]),
        };
    }
};

pub const Symlink = struct {
    hard_links: u32,
    target: []const u8,
    // xattr_idx is ignored on extended symlinks as you can't apply them to symlinks anyway.

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

pub const Dev = struct {
    hard_links: u32,
    device: u32,
    // xattr_idx omitted on basic device inodes.
    xattr_idx: ?u32,

    pub fn readBasic(rdr: *Io.Reader) !Dev {
        var raw: [8]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .hard_links = util.readValue(u32, raw[0..4]),
            .device = util.readValue(u32, raw[4..8]),
            .xattr_idx = null,
        };
    }
    pub fn readExt(rdr: *Io.Reader) !Dev {
        var raw: [12]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .hard_links = util.readValue(u32, raw[0..4]),
            .device = util.readValue(u32, raw[4..8]),
            .xattr_idx = util.readValue(u32, raw[8..12]),
        };
    }
};

pub const Fifo = struct {
    hard_links: u32,
    // Xattr_idx omitted on basic fifo inodes.
    xattr_idx: ?u32,

    pub fn readBasic(rdr: *Io.Reader) !Fifo {
        var raw: [4]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .hard_links = util.readValue(u32, raw[0..4]),
            .xattr_idx = null,
        };
    }
    pub fn readExt(rdr: *Io.Reader) !Fifo {
        var raw: [8]u8 = undefined;
        try rdr.readSliceAll(&raw);

        return .{
            .hard_links = util.readValue(u32, raw[0..4]),
            .xattr_idx = util.readValue(u32, raw[4..8]),
        };
    }
};

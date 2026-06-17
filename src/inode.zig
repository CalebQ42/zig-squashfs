const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;

const Decomp = @import("decomp.zig");
const Directory = @import("directory.zig");
const MetadataReader = @import("meta_rdr.zig");
const Superblock = @import("archive.zig").Superblock;
const Extract = @import("extract.zig");
const ExtractionOptions = @import("options.zig");

const Inode = @This();

hdr: Header,
data: Data,

pub fn init(alloc: std.mem.Allocator, block_size: u32, rdr: *Reader) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);

    const data: Data = switch (hdr.type) {
        .dir => .{ .dir = try .init(rdr) },
        .ext_dir => .{ .ext_dir = try .init(rdr) },
        .file => .{ .file = try .init(alloc, rdr, block_size) },
        .ext_file => .{ .ext_file = try .init(alloc, rdr, block_size) },
        .symlink => .{ .symlink = try .init(alloc, rdr) },
        .ext_symlink => .{ .ext_symlink = try .init(alloc, rdr) },
        .block_dev => .{ .block_dev = try .init(rdr) },
        .ext_block_dev => .{ .ext_block_dev = try .init(rdr) },
        .char_dev => .{ .char_dev = try .init(rdr) },
        .ext_char_dev => .{ .ext_char_dev = try .init(rdr) },
        .fifo => .{ .fifo = try .init(rdr) },
        .ext_fifo => .{ .ext_fifo = try .init(rdr) },
        .socket => .{ .socket = try .init(rdr) },
        .ext_socket => .{ .ext_socket = try .init(rdr) },
    };
    return .{ .hdr = hdr, .data = data };
}
pub fn initRef(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, inode_start: u64, block_size: u32, ref: Ref) !Inode {
    var meta: MetadataReader = .init(alloc, data, decomp, inode_start + ref.block_start);
    try meta.interface.discardAll(ref.block_offset);

    return .init(alloc, block_size, &meta.interface);
}
pub fn initEntry(alloc: std.mem.Allocator, data: []u8, decomp: Decomp.Fn, inode_start: u64, block_size: u32, entry: Directory.Entry) !Inode {
    var meta: MetadataReader = .init(alloc, data, decomp, inode_start + entry.block_start);
    try meta.interface.discardAll(entry.block_offset);

    return .init(alloc, block_size, &meta.interface);
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

pub fn extract(self: Inode, alloc: std.mem.Allocator, io: Io, super: Superblock, data: []u8, decomp: Decomp.Fn, location: []const u8, options: ExtractionOptions) !void {
    return Extract.extract(alloc, io, super, data, decomp, self, location, options);
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

pub const Header = extern struct {
    type: Type,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Data = union(Type) {
    dir: Dir,
    file: File,
    symlink: Symlink,
    block_dev: Dev,
    char_dev: Dev,
    fifo: IPC,
    socket: IPC,
    ext_dir: ExtDir,
    ext_file: ExtFile,
    ext_symlink: ExtSymlink,
    ext_block_dev: ExtDev,
    ext_char_dev: ExtDev,
    ext_fifo: ExtIPC,
    ext_socket: ExtIPC,
};

pub const DataBlock = packed struct(u32) {
    size: u24,
    uncompressed: bool,
    _: u7,
};

pub const Dir = extern struct {
    block_start: u32,
    hard_links: u32,
    size: u16,
    block_offset: u16,
    parent_num: u32,

    fn init(rdr: *Reader) !Dir {
        var new: Dir = undefined;
        try rdr.readSliceEndian(Dir, @ptrCast(&new), .little);
        return new;
    }
};
pub const ExtDir = extern struct {
    hard_links: u32,
    size: u32,
    block_start: u32,
    parent_num: u32,
    idx_count: u16,
    block_offset: u16,
    xattr_idx: u32,

    fn init(rdr: *Reader) !ExtDir {
        var new: ExtDir = undefined;
        try rdr.readSliceEndian(ExtDir, @ptrCast(&new), .little);
        return new;
    }
};
pub const File = struct {
    block_start: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    blocks: []DataBlock,

    fn init(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !File {
        var data: [16]u8 = undefined;
        try rdr.readSliceAll(&data);

        const frag_idx = std.mem.readInt(u32, data[4..8], .little);
        const size = std.mem.readInt(u32, data[12..], .little);

        var blocks_num = size / block_size;
        if (size % block_size != 0 and frag_idx == 0xFFFFFFFF)
            blocks_num += 1;

        const blocks = try alloc.alloc(DataBlock, blocks_num);
        try rdr.readSliceEndian(DataBlock, blocks, .little);

        return .{
            .block_start = std.mem.readInt(u32, data[0..4], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, data[8..12], .little),
            .size = size,
            .blocks = blocks,
        };
    }
};
pub const ExtFile = struct {
    block_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    blocks: []DataBlock,

    fn init(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !ExtFile {
        var data: [40]u8 = undefined;
        try rdr.readSliceAll(&data);

        const frag_idx = std.mem.readInt(u32, data[28..32], .little);
        const size = std.mem.readInt(u64, data[8..16], .little);

        var blocks_num = size / block_size;
        if (size % block_size != 0 and frag_idx == 0xFFFFFFFF)
            blocks_num += 1;

        const blocks = try alloc.alloc(DataBlock, blocks_num);
        try rdr.readSliceEndian(DataBlock, blocks, .little);

        return .{
            .block_start = std.mem.readInt(u64, data[0..8], .little),
            .size = size,
            .sparse = std.mem.readInt(u64, data[16..24], .little),
            .hard_links = std.mem.readInt(u32, data[24..28], .little),
            .frag_idx = frag_idx,
            .frag_offset = std.mem.readInt(u32, data[32..36], .little),
            .xattr_idx = std.mem.readInt(u32, data[36..], .little),
            .blocks = blocks,
        };
    }
};
pub const Symlink = struct {
    hard_links: u32,
    target: []const u8,

    fn init(alloc: std.mem.Allocator, rdr: *Reader) !Symlink {
        var data: [8]u8 = undefined;
        try rdr.readSliceAll(&data);

        const target_size = std.mem.readInt(u32, data[4..], .little);

        const target = try alloc.alloc(u8, target_size);
        try rdr.readSliceEndian(u8, target, .little);

        return .{
            .hard_links = std.mem.readInt(u32, data[0..4], .little),
            .target = target,
        };
    }
};
pub const ExtSymlink = struct {
    hard_links: u32,
    target: []const u8,
    xattr_idx: u32,

    fn init(alloc: std.mem.Allocator, rdr: *Reader) !ExtSymlink {
        const sym: Symlink = try .init(alloc, rdr);

        var xattr_idx: u32 = undefined;
        try rdr.readSliceEndian(u32, @ptrCast(&xattr_idx), .little);

        return .{
            .hard_links = sym.hard_links,
            .target = sym.target,
            .xattr_idx = xattr_idx,
        };
    }
};
pub const Dev = extern struct {
    hard_links: u32,
    device: u32,

    fn init(rdr: *Reader) !Dev {
        var new: Dev = undefined;
        try rdr.readSliceEndian(Dev, @ptrCast(&new), .little);
        return new;
    }
};
pub const ExtDev = extern struct {
    hard_links: u32,
    device: u32,
    xattr_idx: u32,

    fn init(rdr: *Reader) !ExtDev {
        var new: ExtDev = undefined;
        try rdr.readSliceEndian(ExtDev, @ptrCast(&new), .little);
        return new;
    }
};
pub const IPC = extern struct {
    hard_links: u32,

    fn init(rdr: *Reader) !IPC {
        var new: IPC = undefined;
        try rdr.readSliceEndian(IPC, @ptrCast(&new), .little);
        return new;
    }
};
pub const ExtIPC = extern struct {
    hard_links: u32,
    xattr_idx: u32,

    fn init(rdr: *Reader) !ExtIPC {
        var new: ExtIPC = undefined;
        try rdr.readSliceEndian(ExtIPC, @ptrCast(&new), .little);
        return new;
    }
};

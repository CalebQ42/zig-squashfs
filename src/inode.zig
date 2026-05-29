const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;

const DecompCache = @import("decomp_cache.zig");
const Directory = @import("directory.zig");
const MetadataReader = @import("meta_rdr.zig");

const Inode = @This();

hdr: Header,
data: Data,

/// Read an inode given an inode Ref.
pub fn initRef(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, inode_start: u64, block_size: u32, ref: Ref) !Inode {
    var meta: MetadataReader = .init(io, cache, inode_start + ref.block_start);
    defer meta.deinit(io);
    try meta.interface.discardAll(ref.block_offset);

    return .init(alloc, &meta.interface, block_size);
}
pub fn initDirEntry(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, inode_start: u64, block_size: u32, entry: Directory.Entry) !Inode {
    var meta: MetadataReader = .init(io, cache, inode_start + entry.block_start);
    defer meta.deinit(io);
    try meta.interface.discardAll(entry.block_offset);

    return .init(alloc, &meta.interface, block_size);
}
/// Read the inode from the given Reader.
pub fn init(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    const data: Data = switch (hdr.type) {
        .dir => .{ .dir = try .init(rdr) },
        .file => .{ .file = try .init(alloc, rdr, block_size) },
        .symlink => .{ .symlink = try .init(alloc, rdr) },
        .block_dev => .{ .block_dev = try .init(rdr) },
        .char_dev => .{ .char_dev = try .init(rdr) },
        .fifo => .{ .fifo = try .init(rdr) },
        .socket => .{ .socket = try .init(rdr) },
        .ext_dir => .{ .ext_dir = try .init(rdr) },
        .ext_file => .{ .ext_file = try .init(alloc, rdr, block_size) },
        .ext_symlink => .{ .ext_symlink = try .init(alloc, rdr) },
        .ext_block_dev => .{ .ext_block_dev = try .init(rdr) },
        .ext_char_dev => .{ .ext_char_dev = try .init(rdr) },
        .ext_fifo => .{ .ext_fifo = try .init(rdr) },
        .ext_socket => .{ .ext_socket = try .init(rdr) },
    };
    return .{
        .hdr = hdr,
        .data = data,
    };
}
pub fn copy(self: Inode, alloc: std.mem.Allocator) !Inode {
    var new_inode = self;
    switch (new_inode.data) {
        .file => |*f| {
            if (f.blocks.len > 0) {
                f.blocks = try alloc.alloc(DataBlock, f.blocks.len);
                @memcpy(f.blocks, self.data.file.blocks);
            }
        },
        .ext_file => |*f| {
            if (f.blocks.len > 0) {
                f.blocks = try alloc.alloc(DataBlock, f.blocks.len);
                @memcpy(f.blocks, self.data.ext_file.blocks);
            }
        },
        .symlink => |*s| {
            s.target = try alloc.alloc(u8, s.target.len);
            @memcpy(s.target, self.data.symlink.target);
        },
        .ext_symlink => |*s| {
            s.target = try alloc.alloc(u8, s.target.len);
            @memcpy(s.target, self.data.ext_symlink.target);
        },
    }
    return new_inode;
}
pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |f| f.deinit(alloc),
        .ext_file => |f| f.deinit(alloc),
        .symlink => |s| s.deinit(alloc),
        .ext_symlink => |s| s.deinit(alloc),
        else => {},
    }
}

// Utility functions

pub fn directory(self: Inode, alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64) !Directory {
    return switch (self.data) {
        .dir => |d| readDirectory(alloc, io, cache, dir_start, d),
        .ext_dir => |d| readDirectory(alloc, io, cache, dir_start, d),
        else => error.NotDirectory,
    };
}
fn readDirectory(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64, d: anytype) !Directory {
    var meta: MetadataReader = .init(io, cache, dir_start + d.block_start);
    defer meta.deinit(io);
    try meta.interface.discardAll(d.block_offset);

    return .init(alloc, &meta.interface, d.size);
}

// Types

pub const Ref = packed struct(u64) {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const Enum = enum(u16) {
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
    type: Enum,
    permission: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Data = union(Enum) {
    dir: Dir,
    file: File,
    symlink: Symlink,
    block_dev: Device,
    char_dev: Device,
    fifo: IPC,
    socket: IPC,
    ext_dir: ExtDir,
    ext_file: ExtFile,
    ext_symlink: ExtSymlink,
    ext_block_dev: ExtDevice,
    ext_char_dev: ExtDevice,
    ext_fifo: ExtIPC,
    ext_socket: ExtIPC,
};

pub const DataBlock = packed struct(u32) {
    size: u24,
    uncompressed: bool,
    _: u7,
};

const Dir = extern struct {
    block_start: u32,
    hard_links: u32,
    size: u16,
    block_offset: u16,
    parent: u32,

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};
const ExtDir = extern struct {
    hard_links: u32,
    size: u32,
    block_start: u32,
    parent: u32,
    idx_count: u16,
    block_offset: u16,
    xattr_idx: u32,
    // []DirIndex

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};

const File = struct {
    data_start: u32,
    frag_idx: u32,
    frag_offset: u32,
    size: u32,
    blocks: []DataBlock,

    const Raw = extern struct {
        data_start: u32,
        frag_idx: u32,
        frag_offset: u32,
        size: u32,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Self {
        var raw: Raw = undefined;
        try rdr.readSliceEndian(Raw, @ptrCast(&raw), .little);

        var blocks_num = raw.size / block_size;
        if (raw.frag_idx == 0xFFFFFFFF and raw.size % block_size > 0)
            blocks_num += 1;

        const blocks: []DataBlock = try alloc.alloc(DataBlock, blocks_num);
        errdefer alloc.free(blocks);

        try rdr.readSliceEndian(DataBlock, blocks, .little);
        return .{
            .data_start = raw.data_start,
            .frag_idx = raw.frag_idx,
            .frag_offset = raw.frag_offset,
            .size = raw.size,
            .blocks = blocks,
        };
    }
    pub fn deinit(self: File, alloc: std.mem.Allocator) void {
        alloc.free(self.blocks);
    }
};
const ExtFile = struct {
    data_start: u64,
    size: u64,
    sparse: u64,
    hard_links: u32,
    frag_idx: u32,
    frag_offset: u32,
    xattr_idx: u32,
    blocks: []DataBlock,

    const Raw = extern struct {
        data_start: u64,
        size: u64,
        sparse: u64,
        hard_links: u32,
        frag_idx: u32,
        frag_offset: u32,
        xattr_idx: u32,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Self {
        var raw: Raw = undefined;
        try rdr.readSliceEndian(Raw, @ptrCast(&raw), .little);

        var blocks_num = raw.size / block_size;
        if (raw.frag_idx == 0xFFFFFFFF and raw.size % block_size > 0)
            blocks_num += 1;

        const blocks: []DataBlock = try alloc.alloc(DataBlock, blocks_num);
        errdefer alloc.free(blocks);

        try rdr.readSliceEndian(DataBlock, blocks, .little);
        return .{
            .data_start = raw.data_start,
            .size = raw.size,
            .sparse = raw.sparse,
            .hard_links = raw.hard_links,
            .frag_idx = raw.frag_idx,
            .frag_offset = raw.frag_offset,
            .xattr_idx = raw.xattr_idx,
            .blocks = blocks,
        };
    }
    pub fn deinit(self: File, alloc: std.mem.Allocator) void {
        alloc.free(self.blocks);
    }
};

const Symlink = struct {
    hard_links: u32,
    target: []const u8,

    const Raw = extern struct {
        hard_links: u32,
        target_size: u32,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, rdr: *Reader) !Self {
        var raw: Raw = undefined;
        try rdr.readSliceEndian(Raw, @ptrCast(&raw), .little);

        const target = try alloc.alloc(u8, raw.target_size);
        try rdr.readSliceEndian(u8, target, .little);

        return .{
            .hard_links = raw.hard_links,
            .target = target,
        };
    }
    pub fn deinit(self: Symlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};
const ExtSymlink = struct {
    hard_links: u32,
    xattr_idx: u32,
    target: []const u8,

    const Raw = extern struct {
        hard_links: u32,
        target_size: u32,
    };

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, rdr: *Reader) !Self {
        var raw: Raw = undefined;
        try rdr.readSliceEndian(Raw, @ptrCast(&raw), .little);

        const target = try alloc.alloc(u8, raw.target_size);
        errdefer alloc.free(target);
        try rdr.readSliceEndian(u8, target, .little);

        var xattr_idx: u32 = undefined;
        try rdr.readSliceEndian(u32, @ptrCast(&xattr_idx), .little);

        return .{
            .hard_links = raw.hard_links,
            .target = target,
            .xattr_idx = xattr_idx,
        };
    }

    pub fn deinit(self: Symlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

const Device = extern struct {
    hard_links: u32,
    device: u32,

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};
const ExtDevice = extern struct {
    hard_links: u32,
    device: u32,
    xattr_idx: u32,

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};

const IPC = extern struct {
    hard_links: u32,

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};
const ExtIPC = extern struct {
    hard_links: u32,
    xattr_idx: u32,

    const Self = @This();

    fn init(rdr: *Reader) !Self {
        var dir: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&dir), .little);
        return dir;
    }
};

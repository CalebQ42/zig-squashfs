//! A file-system object. Represents a File or directory.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;

const DirEntry = @import("dir_entry.zig");
const DirTypes = @import("inode_data/dir.zig");
const FileTypes = @import("inode_data/file.zig");
const MiscTypes = @import("inode_data/misc.zig");
const DecompCache = @import("util/decomp_cache.zig");
const MetadataReader = @import("util/metadata.zig");

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
    dir: DirTypes.Dir,
    file: FileTypes.File,
    symlink: MiscTypes.Symlink,
    block_dev: MiscTypes.Dev,
    char_dev: MiscTypes.Dev,
    fifo: MiscTypes.IPC,
    socket: MiscTypes.IPC,
    ext_dir: DirTypes.ExtDir,
    ext_file: FileTypes.ExtFile,
    ext_symlink: MiscTypes.ExtSymlink,
    ext_block_dev: MiscTypes.ExtDev,
    ext_char_dev: MiscTypes.ExtDev,
    ext_fifo: MiscTypes.ExtIPC,
    ext_socket: MiscTypes.ExtIPC,
};

pub const Header = packed struct {
    inode_type: Type,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Error = error{
    NotDirectory,
};

const Inode = @This();

hdr: Header,
data: Data,

pub fn fromRef(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, inode_start: u64, block_size: u32, ref: Ref) !Inode {
    var meta: MetadataReader = .init(io, cache, ref.block_start + inode_start);
    defer meta.deinit();
    try meta.interface.discardAll(ref.block_offset);
    return fromReader(alloc, &meta.interface, block_size);
}
pub fn fromReader(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    return .{
        .hdr = hdr,
        .data = switch (hdr.inode_type) {
            .dir => .{ .dir = try .read(rdr) },
            .file => .{ .file = try .read(alloc, rdr, block_size) },
            .symlink => .{ .symlink = try .read(alloc, rdr) },
            .block_dev => .{ .block_dev = try .read(rdr) },
            .char_dev => .{ .char_dev = try .read(rdr) },
            .fifo => .{ .fifo = try .read(rdr) },
            .socket => .{ .socket = try .read(rdr) },
            .ext_dir => .{ .ext_dir = try .read(rdr) },
            .ext_file => .{ .ext_file = try .read(alloc, rdr, block_size) },
            .ext_symlink => .{ .ext_symlink = try .read(alloc, rdr) },
            .ext_block_dev => .{ .ext_block_dev = try .read(rdr) },
            .ext_char_dev => .{ .ext_char_dev = try .read(rdr) },
            .ext_fifo => .{ .ext_fifo = try .read(rdr) },
            .ext_socket => .{ .ext_socket = try .read(rdr) },
        },
    };
}
pub fn copy(alloc: std.mem.Allocator, from: Inode) !Inode {
    var new = from;
    switch (from.data) {
        .file => |f| {
            new.data.file.block_sizes = try alloc.alloc(FileTypes.BlockSize, f.block_sizes.len);
            @memcpy(new.data.file.block_sizes, f.block_sizes);
        },
        .ext_file => |f| {
            new.data.ext_file.block_sizes = try alloc.alloc(FileTypes.BlockSize, f.block_sizes.len);
            @memcpy(new.data.ext_file.block_sizes, f.block_sizes);
        },
        .symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            new.data.symlink.target = new_target;
        },
        .ext_symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            new.data.ext_symlink.target = new_target;
        },
        else => {},
    }
    return new;
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

pub fn readDirectory(self: Inode, alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64) ![]DirEntry {
    return switch (self.data) {
        .dir => |d| readDirectoryFromData(alloc, io, cache, dir_start, d),
        .ext_dir => |d| readDirectoryFromData(alloc, io, cache, dir_start, d),
        else => Error.NotDirectory,
    };
}
fn readDirectoryFromData(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64, d: anytype) ![]DirEntry {
    var meta: MetadataReader = .init(io, cache, dir_start + d.block_start);
    defer meta.deinit();
    try meta.interface.discardAll(d.block_offset);

    return DirEntry.readEntries(alloc, &meta.interface, d.size);
}

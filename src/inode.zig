//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const Io = std.Io;

const DirEntry = @import("directory.zig");
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const DataExtractor = @import("util/data_extractor.zig");
const DataReader = @import("util/data_reader.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const SharedCache = @import("util/shared_cache.zig");

const Inode = @This();

hdr: Header,
data: Data,

pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
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
pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |d| d.deinit(alloc),
        .symlink => |d| d.deinit(alloc),
        .ext_file => |d| d.deinit(alloc),
        .ext_symlink => |d| d.deinit(alloc),
        else => {},
    }
}

// Utility Functions

/// Read the directory entries
pub fn readDirectory(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, dir_offset: u64) ![]DirEntry {
    return switch (self.data) {
        .dir => |d| readDirFromData(alloc, io, fil, decomp, dir_offset, d),
        .ext_dir => |d| readDirFromData(alloc, io, fil, decomp, dir_offset, d),
        else => Error.NotDirectory,
    };
}
fn readDirFromData(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, dir_offset: u64, d: anytype) ![]DirEntry {
    var rdr = try fil.readerAt(io, dir_offset + d.block_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, decomp);
    try meta.interface.discardAll(d.block_offset);

    return DirEntry.readDirectory(alloc, &meta.interface, d.size);
}
/// Get a reader for a regular file's data.
pub fn dataReader(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, cache: *SharedCache, decomp: *const Decompressor, block_size: u32) !DataReader {
    return switch (self.data) {
        .file => |f| getReaderFromData(alloc, io, fil, cache, decomp, block_size, f),
        .ext_file => |f| getReaderFromData(alloc, io, fil, cache, decomp, block_size, f),
        else => Error.NotRegularFile,
    };
}
fn getReaderFromData(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, cache: *SharedCache, decomp: *const Decompressor, block_size: u32, d: anytype) !DataReader {
    const ext: DataReader = .init(alloc, io, fil, cache, decomp, block_size, d.size, d.block_start, d.blocks);
    if (d.frag_block_offset == 0xFFFFFFFF) {
        // TODO:
        return error.TODO;
    }
    return ext;
}
/// Get an extractor for a regular file's data.
pub fn dataExtractor(self: Inode, fil: OffsetFile, cache: *SharedCache, decomp: *const Decompressor, block_size: u32) !DataExtractor {
    return switch (self.data) {
        .file => |f| getExtractorFromData(fil, cache, decomp, block_size, f),
        .ext_file => |f| getExtractorFromData(fil, cache, decomp, block_size, f),
        else => Error.NotRegularFile,
    };
}
fn getExtractorFromData(fil: OffsetFile, cache: *SharedCache, decomp: *const Decompressor, block_size: u32, d: anytype) !DataExtractor {
    const ext: DataExtractor = .init(fil, cache, decomp, block_size, d.size, d.block_start, d.blocks);
    if (d.frag_block_offset == 0xFFFFFFFF) {
        // TODO:
        return error.TODO;
    }
    return ext;
}

// Types

pub const Error = error{
    NotDirectory,
    NotRegularFile,
    NotExtended,
};

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

pub const Header = extern struct {
    inode_type: Type,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

//! This is the raw squashfs representation of a file/directory.
//! Most of the time using File is a better experience and using Inodes directory
//! is only required for more technical use cases.

const std = @import("std");
const Reader = std.Io.Reader;

const Decompressor = @import("decomp.zig");
const Directory = @import("directory.zig");
const FragEntry = @import("archive.zig").FragEntry;
const Dir = @import("inode/dir.zig");
const File = @import("inode/file.zig");
const Misc = @import("inode/misc.zig");
const Sym = @import("inode/sym.zig");
const LookupTable = @import("lookup_table.zig");
const MinimalSuperblock = @import("archive.zig").MinimalSuperblock;
const DataReader = @import("util/data_reader.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

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
pub fn copy(self: Inode, alloc: std.mem.Allocator) !Inode {
    switch (self.data) {
        .dir,
        .ext_dir,
        .block,
        .ext_block,
        .char,
        .ext_char,
        .fifo,
        .ext_fifo,
        .sock,
        .ext_sock,
        => return self,
        .file => |f| {
            const new_sizes = try alloc.alloc(File.BlockSize, f.block_sizes.len);
            @memcpy(new_sizes, f.block_sizes);
            return .{
                .hdr = self.hdr,
                .data = .{ .file = .{
                    .block_start = f.block_start,
                    .frag_idx = f.frag_idx,
                    .block_offset = f.block_offset,
                    .size = f.size,
                    .block_sizes = new_sizes,
                } },
            };
        },
        .ext_file => |f| {
            const new_sizes = try alloc.alloc(File.BlockSize, f.block_sizes.len);
            @memcpy(new_sizes, f.block_sizes);
            return .{
                .hdr = self.hdr,
                .data = .{ .ext_file = .{
                    .block_start = self.block_start,
                    .size = self.size,
                    .sparse = self.sparse,
                    .hard_links = self.hard_links,
                    .frag_idx = self.frag_idx,
                    .block_offset = self.block_offset,
                    .xattr_idx = self.xattr_idx,
                    .block_sizes = new_sizes,
                } },
            };
        },
        .symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            return .{
                .hdr = self.hdr,
                .data = .{ .symlink = .{
                    .hard_links = s.hard_links,
                    .target = new_target,
                } },
            };
        },
        .ext_symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            return .{
                .hdr = self.hdr,
                .data = .{ .ext_symlink = .{
                    .hard_links = s.hard_links,
                    .xattr_idx = s.xattr_idx,
                    .target = new_target,
                } },
            };
        },
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

// Errors

pub const Error = error{
    NotDirectory,
    NotFound,
    NotRegularFile,
};

// Utils functions

// Universal

pub fn uid(self: Inode, decomp: *const Decompressor, fil: OffsetFile, id_start: u64) !u16 {
    return LookupTable.stateless(u16, fil, decomp, id_start, self.hdr.uid_idx);
}
pub fn uidCached(self: Inode, table: LookupTable.CachedTable(u16)) !u16 {
    return table.get(self.hdr.uid_idx);
}
pub fn gid(self: Inode, decomp: *const Decompressor, fil: OffsetFile, id_start: u64) !u16 {
    return LookupTable.stateless(u16, fil, decomp, id_start, self.hdr.gid_idx);
}
pub fn gidCached(self: Inode, table: LookupTable.CachedTable(u16)) !u16 {
    return table.get(self.hdr.gid_idx);
}
pub fn xattr(self: Inode, alloc: std.mem.Allocator, decomp: *const Decompressor, fil: OffsetFile, xattr_start: u64) !?LookupTable.XattrValues {
    if (@intFromEnum(self.hdr.inode_type) < 8) return null;
    const idx: u32 = switch (self.data) {
        .ext_dir => |d| d.xattr_idx,
        .ext_file => |f| f.xattr_idx,
        .ext_symlink => |s| s.xattr_idx,
        .ext_block, .ext_char => |d| d.xattr_idx,
        .ext_fifo, .ext_sock => |d| d.xattr_idx,
        else => unreachable,
    };
    if (idx == 0xFFFFFFFF) return null;
    return LookupTable.statelessXattr(alloc, fil, decomp, xattr_start, idx);
}

// Dir inodes

/// For directory inodes, tries to find the inode at the given path. Returns both the inode, and it's file name.
/// If the path is empty or "." then a copy of this inode is returned with no name ("").
pub fn findInode(
    inode: Inode,
    alloc: std.mem.Allocator,
    decomp: *const Decompressor,
    fil: OffsetFile,
    dir_start: u64,
    inode_start: u64,
    block_size: u32,
    filepath: []const u8,
) !struct { inode: Inode, name: []const u8 } {
    switch (inode.data) {
        .dir => |d| {
            const path: []const u8 = std.mem.trim(u8, filepath, "/");
            if (path.len == 0 or (path.len == 1 and path[0] == '.'))
                return .{ .inode = inode.copy(alloc), .name = "" };
            return findInodeRaw(
                alloc,
                decomp,
                fil,
                dir_start,
                inode_start,
                block_size,
                path,
                d,
            );
        },
        .ext_dir => |d| {
            const path: []const u8 = std.mem.trim(u8, filepath, "/");
            if (path.len == 0 or (path.len == 1 and path[0] == '.'))
                return .{ .inode = inode.copy(alloc), .name = "" };
            return findInodeRaw(
                alloc,
                decomp,
                fil,
                dir_start,
                inode_start,
                block_size,
                path,
                d,
            );
        },
        else => return Error.NotDirectory,
    }
}
inline fn findInodeRaw(
    inode: Inode,
    alloc: std.mem.Allocator,
    decomp: *const Decompressor,
    fil: OffsetFile,
    dir_start: u64,
    inode_start: u64,
    block_size: u32,
    path: []const u8,
    dat: anytype,
) !struct { inode: Inode, name: []const u8 } {
    const first_element: []const u8 = std.mem.sliceTo(path, '/');

    const dirs = try readDirRaw(alloc, decomp, fil, dir_start, dat);
    defer {
        for (dirs) |dir|
            dir.deinit(alloc);
        alloc.free(dirs);
    }

    // Directories are stored ASCIIbetically, so we can use binary search.
    var cur_slice = dirs;
    var idx: usize = 0;
    while (cur_slice.len > 0) {
        idx = cur_slice.len / 2;
        const mid_name = cur_slice[idx].name;
        switch (std.mem.order(u8, first_element, mid_name)) {
            .gt => {
                cur_slice = cur_slice[idx + 1 ..];
                continue;
            },
            .lt => {
                cur_slice = cur_slice[0..idx];
                continue;
            },
            .eq => break,
        }
    } else return Error.NotFound;
    const entry = cur_slice[idx];
    var rdr = try fil.readerAt(inode_start + entry.block_start, &[0]u8{});
    var meta_rdr: MetadataReader = .init(&rdr.interface, decomp);
    try meta_rdr.interface.discardAll(entry.block_offset);
    const ret_inode: Inode = try .read(alloc, &meta_rdr.interface, block_size);
    if (first_element.len == path.len) {
        const name_copy = try alloc.alloc(u8, entry.name.len);
        @memcpy(name_copy, entry.name.len);
        return .{ .inode = ret_inode, .name = name_copy };
    }
    return inode.findInode(alloc, decomp, fil, dir_start, inode_start, block_size, path[first_element.len..]);
}

/// Get the directory entries for a directory inode.
pub fn readDirectory(inode: Inode, alloc: std.mem.Allocator, decomp: *const Decompressor, fil: OffsetFile, dir_start: u64) ![]Directory.Entry {
    return switch (inode.data) {
        .dir => |d| readDirRaw(alloc, decomp, fil, dir_start, d),
        .ext_dir => |d| readDirRaw(alloc, decomp, fil, dir_start, d),
        else => Error.NotDirectory,
    };
}
inline fn readDirRaw(alloc: std.mem.Allocator, decomp: *const Decompressor, fil: OffsetFile, dir_start: u64, dat: anytype) ![]Directory.Entry {
    var rdr = try fil.readerAt(dir_start + dat.block_start, &[0]u8{});
    var meta_rdr: MetadataReader = .init(&rdr.interface, decomp);
    try meta_rdr.interface.discardAll(dat.block_offset);
    return Directory.readDirectory(alloc, meta_rdr, dat.size);
}

// file inodes

/// Gets the data reader for a file inode.
pub fn dataReader(inode: Inode, decomp: *const Decompressor, fil: OffsetFile, frag_start: u64, block_size: u32) !DataReader {
    return switch (inode.data) {
        .file => |f| dataReaderRaw(decomp, fil, frag_start, block_size, f),
        .ext_file => |f| dataReaderRaw(decomp, fil, frag_start, block_size, f),
        else => Error.NotRegularFile,
    };
}
inline fn dataReaderRaw(decomp: *const Decompressor, fil: OffsetFile, frag_start: u64, block_size: u32, dat: anytype) !DataReader {
    return .init(
        decomp,
        fil,
        block_size,
        dat.block_sizes,
        dat.size,
        dat.block_start,
        if (dat.frag_idx != 0xFFFFFFFF)
            try LookupTable.stateless(FragEntry, fil, decomp, frag_start, dat.frag_idx)
        else
            null,
        dat.frag_offset,
    );
}

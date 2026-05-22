//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const Io = std.Io;

const Archive = @import("archive.zig");
const Decomp = @import("decomp.zig").Decomp;
const DirEntry = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const FragEntry = @import("frag.zig").FragEntry;
const FragManager = @import("frag.zig");
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const LookupTable = @import("lookup_table.zig");
const CachedTable = LookupTable.CachedTable;
const DataExtractor = @import("util/data_extractor.zig");
const DataReader = @import("util/data_reader.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const SharedCache = @import("util/shared_cache.zig");
const XattrTable = @import("xattr_table.zig");

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
fn readDirFromData(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *const Decompressor, dir_offset: u64, d: anytype) ![]DirEntry {
    var rdr = fil.readerAt(dir_offset + d.block_start);
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
/// Get a symlink's target path
pub fn symlinkTarget(self: Inode) ![]const u8 {
    return switch (self.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => Error.NotSymlink,
    };
}
/// Get inode's gid
pub fn gid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, id_table_start: u64) !u16 {
    return LookupTable.lookupValue(u16, alloc, io, decomp, fil, id_table_start, self.hdr.gid_idx);
}
/// Get inode's uid
pub fn uid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, id_table_start: u64) !u16 {
    return LookupTable.lookupValue(u16, alloc, io, decomp, fil, id_table_start, self.hdr.uid_idx);
}
/// Get the inode's xattr values as an index into the Archive's xattr table.
/// Returns error.NoXattr if the inode doesn't have extended attributes.
pub fn xattrIndex(self: Inode) !u32 {
    const idx = switch (self.data) {
        .ext_dir => |e| e.xattr_idx,
        .ext_file => |e| e.xattr_idx,
        .ext_symlink => |e| e.xattr_idx,
        .ext_block_dev => |e| e.xattr_idx,
        .ext_char_dev => |e| e.xattr_idx,
        .ext_fifo => |e| e.xattr_idx,
        .ext_socket => |e| e.xattr_idx,
        else => Error.NoXattr,
    };
    if (idx == 0xFFFFFFFF) return Error.NoXattr;
    return idx;
}
// Get an inode's xattr values. If the inode does not have xattr values (including if the inode is not an extended type), an empty slice is returned.
pub fn xattrValues(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, xattr_table_start: u64) ![]XattrTable.XattrOwned {
    const idx = self.xattrIndex() catch &[0]XattrTable.XattrOwned{};
    return XattrTable.statelessLookup(alloc, io, decomp, fil, xattr_table_start, idx);
}

// Types

pub const Error = error{
    NotDirectory,
    NotRegularFile,
    NotSymlink,
    NotExtended,
};

pub const Ref = packed struct(u64) {
    block_offset: u16,
    block_start: u32,
    _: u16 = 0,
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

// Extract

const ExtractError = error{ MknodFailed, CannotSetXattr, ConcurrencyUnavailable } || DataExtractor.Error || Io.Dir.CreateFileAtomicError || LookupTable.Error ||
    Io.File.Reader.SeekError || Io.File.Atomic.LinkError || Io.Dir.CreateDirError || Io.File.OpenError ||
    Io.File.SetPermissionsError || Io.File.SetOwnerError || Io.Dir.SymLinkError || Io.Dir.CreateDirPathError;
const PathRet = struct {
    path: []const u8,
    inode: Inode,
    xattr_idx: ?u32 = null,
};
fn DirCompare(_: void, a: PathRet, b: PathRet) std.math.Order {
    return std.math.order(std.mem.count(u8, a.path, "/"), std.mem.count(u8, b.path, "/"));
}
const ExtractReturnUnion = union(enum) {
    path_ret: ExtractError!PathRet,
};
const Tables = struct {
    id: LookupTable.CachedTable(u16),
    frag: LookupTable.CachedTable(FragEntry),
    xattr: XattrTable,
};

/// Extracts the given inode to the given path. If the inode not a directory, the given path must not exist.
/// If the inode is a directory the path must not exist or be a directory.
pub fn extract(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    super: Archive.Superblock,
    filepath: []const u8,
    options: ExtractionOptions,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = fil;
    _ = super;
    _ = filepath;
    _ = options;
    return error.TODO;
}

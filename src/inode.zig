//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const Io = std.Io;

const Archive = @import("archive.zig");
const Decomp = @import("decomp.zig").Decomp;
const DirEntry = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const FragEntry = @import("frag.zig").FragEntry;
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
    const path = std.mem.trimEnd(u8, filepath, "/");

    var decomp_base: Decomp = switch (super.compression) {
        .gzip => .{ .gzip = try .init(alloc, super.block_size) },
        .lzma => .{ .lzma = try .init(alloc, super.block_size) },
        .xz => .{ .xz = try .init(alloc, super.block_size) },
        .zstd => .{ .zstd = try .init(alloc, io, super.block_size) },
        else => unreachable,
    };
    defer decomp_base.deinit();
    const decomp = decomp_base.decompressor();

    var frag_table: CachedTable(FragEntry) = .init(alloc, fil, decomp, super.frag_start, super.frag_count);
    defer if (!options.ignore_permissions) frag_table.deinit(io);
    try frag_table.fill(io);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    var sel_buf = [1]ExtractReturnUnion{undefined} ** 10;
    var sel: Io.Select(ExtractReturnUnion) = .init(io, &sel_buf);
    defer sel.cancelDiscard();

    switch (self.hdr.inode_type) {
        .dir, .ext_dir => try sel.concurrent(
            .path_ret,
            extractDir,
            .{ self, alloc, io, fil, decomp, &sel, &arena, super.dir_start, super.inode_start, &frag_table, super.block_size, path },
        ),
        .file, .ext_file => try sel.concurrent(
            .path_ret,
            extractFile,
            .{ self, alloc, io, fil, decomp, &frag_table, super.block_size, path },
        ),
        .symlink, .ext_symlink => try sel.concurrent(.path_ret, extractSymlink, .{ self, io, path }),
        else => if (@hasField(std.os, "linux"))
            try sel.concurrent(.path_ret, extractDevOrIPC, .{ self, alloc, path }),
    }

    var xattr_table: ?XattrTable = if (!options.ignore_xattr)
        try .init(alloc, io, fil, decomp, super.xattr_start)
    else
        null;
    defer if (!options.ignore_xattr) xattr_table.?.deinit(io);
    if (xattr_table != null) try xattr_table.?.table.fill(io);

    var id_table: ?CachedTable(u16) = if (!options.ignore_xattr)
        .init(alloc, fil, decomp, super.id_start, super.id_count)
    else
        null;
    defer if (!options.ignore_xattr) id_table.?.deinit(io);
    if (id_table != null) try id_table.?.fill(io);

    while (true) {
        const group_token = sel.group.token.load(.acquire);
        if (group_token == null) break;
        // std.debug.print("{any}\n", .{sel.group.state});

        // std.debug.print("Waiting for return...", .{});
        const ret = try sel.await();
        // std.debug.print("Got One...\n", .{});
        const path_ret = try ret.path_ret;

        if (options.ignore_permissions and options.ignore_xattr) continue;
        if (options.ignore_permissions and path_ret.xattr_idx == null) continue;

        var ret_file = try Io.Dir.cwd().openFile(io, path_ret.path, .{});
        defer ret_file.close(io);

        if (!options.ignore_permissions) {
            try ret_file.setPermissions(io, @enumFromInt(path_ret.inode.hdr.permissions));
            try ret_file.setOwner(
                io,
                try id_table.?.get(io, path_ret.inode.hdr.uid_idx),
                try id_table.?.get(io, path_ret.inode.hdr.gid_idx),
            );
        }
        if (@hasField(std.os, "linux") and !options.ignore_xattr and path_ret.xattr_idx != null) {
            const xattrs = try xattr_table.?.get(alloc, io, path_ret.xattr_idx.?);
            defer {
                for (xattrs) |x|
                    alloc.free(x.key);
                alloc.free(xattrs);
            }

            for (xattrs) |x| {
                const res = std.os.linux.fsetxattr(ret_file.handle, x.key, x.value.ptr, x.value.len, 0);
                if (res != 0)
                    return error.CannotSetXattr;
            }
        }
    }
}
fn extractDir(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    decomp: *const Decompressor,
    parent_select: *Io.Select(ExtractReturnUnion),
    arena: *std.heap.ArenaAllocator,
    dir_start: u64,
    inode_start: u64,
    frag: *CachedTable(FragEntry),
    block_size: u32,
    path: []const u8,
) ExtractError!PathRet {
    try Io.Dir.cwd().createDirPath(io, path);

    var sel_buf = [1]ExtractReturnUnion{undefined} ** 10;
    var sel: Io.Select(ExtractReturnUnion) = .init(io, &sel_buf);
    defer sel.cancelDiscard();

    var num: usize = 0;
    {
        const dir_entries = self.readDirectory(alloc, io, fil, decomp, dir_start) catch |err| switch (err) {
            Error.NotDirectory => unreachable,
            else => return @errorCast(err),
        };
        num = dir_entries.len;
        defer {
            for (dir_entries) |d|
                d.deinit(alloc);
            alloc.free(dir_entries);
        }

        for (dir_entries) |d| {
            var rdr = try fil.readerAt(io, d.block_start + inode_start, &[0]u8{});
            var meta_rdr: MetadataReader = .init(alloc, &rdr.interface, decomp);
            try meta_rdr.interface.discardAll(d.block_offset);
            const inode = try read(arena.allocator(), &meta_rdr.interface, block_size);
            errdefer inode.deinit(arena.allocator());

            const new_path = try std.mem.concat(arena.allocator(), u8, &[_][]const u8{ path, "/", d.name });
            errdefer arena.allocator().free(new_path);

            switch (d.type) {
                .dir => try sel.concurrent(
                    .path_ret,
                    extractDir,
                    .{ inode, alloc, io, fil, decomp, parent_select, arena, dir_start, inode_start, frag, block_size, new_path },
                ),
                .file => try sel.concurrent(
                    .path_ret,
                    extractFile,
                    .{ inode, alloc, io, fil, decomp, frag, block_size, new_path },
                ),
                .symlink => try sel.concurrent(.path_ret, extractSymlink, .{ inode, io, new_path }),
                else => try sel.concurrent(.path_ret, extractDevOrIPC, .{ inode, alloc, new_path }),
            }
        }
    }

    while (num > 0) {
        const ret = sel.await() catch break;
        num -= 1;

        parent_select.queue.putOne(io, ret) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => break,
        };
    }
    return .{
        .path = path,
        .inode = self,
    };
}
fn extractFile(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    decomp: *const Decompressor,
    frag: *CachedTable(FragEntry),
    block_size: u32,
    path: []const u8,
) ExtractError!PathRet {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    var ret: PathRet = .{
        .inode = self,
        .path = path,
    };
    const data: DataExtractor = blk: {
        switch (self.data) {
            .file => |f| {
                var data: DataExtractor = .init(fil, decomp, block_size, f.size, f.block_start, f.block_sizes);
                if (f.frag_idx != 0xFFFFFFFF)
                    data.addFrag(f.frag_block_offset, try frag.get(io, f.frag_idx));

                break :blk data;
            },
            .ext_file => |f| {
                if (f.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = f.xattr_idx;
                var data: DataExtractor = .init(fil, decomp, block_size, f.size, f.block_start, f.block_sizes);
                if (f.frag_idx != 0xFFFFFFFF)
                    data.addFrag(f.frag_block_offset, try frag.get(io, f.frag_idx));

                break :blk data;
            },
            else => unreachable,
        }
    };

    try data.extractAsync(alloc, io, atomic.file);
    try atomic.link(io);

    return ret;
}
fn extractSymlink(self: Inode, io: Io, path: []const u8) ExtractError!PathRet {
    const target = switch (self.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };

    try Io.Dir.cwd().symLink(io, target, path, .{});

    return .{
        .path = path,
        .inode = self,
    };
}
fn extractDevOrIPC(self: Inode, alloc: std.mem.Allocator, path: []const u8) ExtractError!PathRet {
    var dev_num: u32 = 0;
    var mode: u32 = 0;

    const DT = std.posix.DT;

    var ret: PathRet = .{
        .inode = self,
        .path = path,
    };

    switch (self.data) {
        .block_dev => |d| {
            dev_num = d.dev;
            mode = DT.BLK;
        },
        .ext_block_dev => |d| {
            dev_num = d.dev;
            mode = DT.BLK;
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;
        },
        .char_dev => |d| {
            dev_num = d.dev;
            mode = DT.CHR;
        },
        .ext_char_dev => |d| {
            dev_num = d.dev;
            mode = DT.CHR;
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;
        },
        .fifo => mode = DT.FIFO,
        .ext_fifo => |f| {
            mode = DT.FIFO;
            if (f.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = f.xattr_idx;
        },
        .socket => mode = DT.SOCK,
        .ext_socket => |s| {
            mode = DT.SOCK;
            if (s.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = s.xattr_idx;
        },
        else => unreachable,
    }

    const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{path}, 0);
    defer alloc.free(sentinel_path);

    const res = std.os.linux.mknod(sentinel_path, mode, dev_num);
    if (res != 0) return ExtractError.MknodFailed;

    return ret;
}

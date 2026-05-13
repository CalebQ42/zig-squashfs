//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const Io = std.Io;

const Archive = @import("archive.zig");
const DirEntry = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const FragEntry = @import("frag.zig").FragEntry;
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const LookupTable = @import("lookup_table.zig");
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
// Get a symlink's target path
pub fn symlinkTarget(self: Inode) ![]const u8 {
    return switch (self.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => Error.NotSymlink,
    };
}
// Get inode's gid
pub fn gid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, id_table_start: u64) !u16 {
    return LookupTable.lookupValue(u16, alloc, io, decomp, fil, id_table_start, self.hdr.gid_idx);
}
// Get inode's uid
pub fn uid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, id_table_start: u64) !u16 {
    return LookupTable.lookupValue(u16, alloc, io, decomp, fil, id_table_start, self.hdr.uid_idx);
}
pub fn xattrIndex(self: Inode) !u32 {
    return switch (self.data) {
        .ext_dir => |e| e.xattr_idx,
        .ext_file => |e| e.xattr_idx,
        .ext_symlink => |e| e.xattr_idx,
        .ext_block_dev => |e| e.xattr_idx,
        .ext_char_dev => |e| e.xattr_idx,
        .ext_fifo => |e| e.xattr_idx,
        .ext_socket => |e| e.xattr_idx,
        else => Error.NotExtended,
    };
}
// Get an inode's xattr values. If the inode does not have xattr values (including if the inode is not an extended type), an empty slice is returned.
pub fn xattrValues(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, xattr_table_start: u64) ![]XattrTable.XattrOwned {
    const idx = switch (self.data) {
        .ext_dir => |e| e.xattr_idx,
        .ext_file => |e| e.xattr_idx,
        .ext_symlink => |e| e.xattr_idx,
        .ext_block_dev => |e| e.xattr_idx,
        .ext_char_dev => |e| e.xattr_idx,
        .ext_fifo => |e| e.xattr_idx,
        .ext_socket => |e| e.xattr_idx,
        else => return &[0]XattrTable.XattrOwned{},
    };
    if (idx == 0xFFFFFFFF) return &[0]XattrTable.XattrOwned{};
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

// Extract

const FileRet = struct {
    file: Io.File,
    inode: Inode,
};
const Tables = struct {
    id: LookupTable.CachedTable(u16),
    frag: LookupTable.CachedTable(FragEntry),
    xattr: XattrTable,
};

pub fn extract(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, super: Archive.Superblock, path: []const u8, options: ExtractionOptions) !void {
    var decomp = switch (super.compression) {
        .gzip => try @import("decomp/zlib.zig").init(alloc, super.block_size),
        .lzma => try @import("decomp/lzma.zig").init(alloc, super.block_size),
        .xz => try @import("decomp/xz.zig").init(alloc, super.block_size),
        .zstd => try @import("decomp/zstd.zig").init(alloc, super.block_size),
        else => unreachable,
    };
    defer decomp.deinit();

    var frag_table: LookupTable.CachedTable(FragEntry) = .init(alloc, fil, &decomp.interface, super.frag_start, super.frag_count);
    defer frag_table.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    var que: Io.Queue(FileRet) = .init(&[1]FileRet{undefined} ** 12);
    defer que.close(io);

    switch (self.hdr.inode_type) {
        .dir, .ext_dir => group.async(io, extractDir, .{
            self,
            alloc,
            io,
            fil,
            &decomp.interface,
            &frag_table,
            super.block_size,
            super.dir_start,
            path,
            options,
            &que,
        }),
        .file, .ext_file => group.async(io, extractRegFile, .{
            self,
            alloc,
            io,
            file,
            &decomp.interface,
            &frag_table,
            super.block_size,
            path,
            options,
            &que,
        }),
        .symlink, .ext_symlink => group.async(Io, extractSymlink, .{ self, io, path, options, &que }),
        else => group.async(io, extractDevice, .{ self, alloc, io, super, path, options, &que }),
    }

    var id_table: LookupTable.CachedTable(u16) = .init(alloc, fil, decomp, super.id_start, super.id_count);
    defer id_table.deinit(io);
    var xattr_table: XattrTable = try .init(alloc, io, fil, decomp, super.xattr_start);
    defer xattr_table.deinit(io);

    for (que.getOne(io)) |res| {
        const ret = res catch break;

        const inode: Inode = ret.inode;
        defer inode.deinit(alloc);
        const ret_file: Io.File = ret.file;
        defer ret_file.close(io);

        if (!options.ignore_xattr) {
            if (inode.xattrIndex()) |idx| {
                const xattrs = try xattr_table.get(io, idx);
                for (xattrs) |x| {
                    // TODO: Check error.
                    const xattr_res = std.os.linux.fsetxattr(ret_file.handle, x.key, x.value.ptr, x.value.len, 0);
                    if (xattr_res != 0 and options.verbose)
                        options.verbose_writer.?.print("setxattr failed with code: {}\n", .{xattr_res}) catch {};
                }
            }
        }
        if (!options.ignore_permissions) {
            try ret_file.setPermissions(io, inode.hdr.permissions);
            try ret_file.setOwner(io, try id_table.get(io, inode.hdr.uid_idx), try id_table.get(io, inode.hdr.gid_idx));
        }
        if (!que.type_erased.closed and group.token.raw == null) que.close(io);
    }
}
pub fn extractDir(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    decomp: *const Decompressor,
    frag: *LookupTable.CachedTable(FragEntry),
    block_size: u32,
    dir_start: u64,
    inode_start: u64,
    path: []const u8,
    options: ExtractionOptions,
    que: *Io.Queue(FileRet),
) !void {
    defer alloc.free(path);

    const dirs = try self.readDirectory(alloc, io, fil, decomp, dir_start);
    defer {
        for (dirs) |d|
            d.deinit(alloc);
        alloc.free(dirs);
    }

    var group: Io.Group = .init;
    defer group.cancel(io);

    for (dirs) |d| {
        var rdr = try fil.readerAt(io, d.block_start + inode_start, &[0]u8{});
        var meta: MetadataReader = .init(alloc, &rdr.interface, decomp);
        try meta.interface.discardAll(d.block_offset);

        const inode = try read(alloc, &meta.interface, block_size);

        const new_path = try std.mem.concat(alloc, u8, &[_][]const u8{ path, "/", d.name });

        switch (inode.hdr.inode_type) {
            .dir, .ext_dir => group.async(io, extractDir, .{
                self,
                alloc,
                io,
                fil,
                &decomp.interface,
                &frag,
                block_size,
                dir_start,
                new_path,
                options,
                &que,
            }),
            .file, .ext_file => group.async(io, extractRegFile, .{
                self,
                alloc,
                io,
                file,
                &decomp.interface,
                &frag,
                block_size,
                new_path,
                options,
                &que,
            }),
            .symlink, .ext_symlink => group.async(Io, extractSymlink, .{ self, alloc, io, new_path, options, &que }),
            else => group.async(io, extractDevice, .{ self, alloc, io, new_path, options, &que }),
        }
    }

    try group.await(io);

    try que.putOne(io, .{ .file = try Io.Dir.cwd().openFile(io, path, .{}), .inode = self });
}
pub fn extractRegFile(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    decomp: *const Decompressor,
    frag: *LookupTable.CachedTable(FragEntry),
    block_size: u32,
    path: []const u8,
    options: ExtractionOptions,
    que: *Io.Queue(FileRet),
) !void {
    _ = options;
    defer alloc.free(path);

    const atom = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atom.deinit(io);

    var size: u64 = undefined;
    var start: u64 = undefined;
    var blocks: []file.BlockSize = undefined;
    var frag_idx: u32 = undefined;
    var frag_offset: u32 = undefined;
    switch (self.data) {
        .file => |f| {
            size = f.size;
            start = f.block_start;
            blocks = f.block_sizes;
            frag_idx = f.frag_idx;
            frag_offset = f.frag_block_offset;
        },
        .ext_file => |f| {
            size = f.size;
            start = f.block_start;
            blocks = f.block_sizes;
            frag_idx = f.frag_idx;
            frag_offset = f.frag_block_offset;
        },
        else => unreachable,
    }

    const ext: DataExtractor = .init(fil, decomp, block_size, size, start, blocks);
    ext.addFrag(frag_offset, try frag.get(io, frag_idx));

    var group: Io.Group = .init;
    defer group.cancel(io);

    ext.extractAsync(alloc, io, &group, atom.file);

    try group.await(io);

    try atom.link(io);

    try que.putOne(io, .{ .file = atom.file, .inode = self });
}
pub fn extractSymlink(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    options: ExtractionOptions,
    que: *Io.Queue(FileRet),
) !void {
    defer alloc.free(path);

    _ = options;
    _ = que;
    // TODO: handle symlink options
    const target = try self.symlinkTarget();

    try Io.Dir.cwd().symLink(io, target, path, .{});

    // TODO: On Linux you can't set permission & xattrs on symlinks (they inherit from their target), but on Mac you can.
}
pub fn extractDevice(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    path: []const u8,
    options: ExtractionOptions,
    que: *Io.Queue(FileRet),
) !void {
    defer alloc.free(path);

    var dev: u32 = 0;
    var mode: u32 = undefined;

    switch (self.data) {
        .char_dev => |d| {
            dev = d.dev;
            mode = std.posix.DT.CHR;
        },
        .block_dev => |d| {
            dev = d.dev;
            mode = std.posix.DT.BLK;
        },
        .ext_char_dev => |d| {
            dev = d.dev;
            mode = std.posix.DT.BLK;
        },
        .ext_block_dev => |d| {
            dev = d.dev;
            mode = std.posix.DT.BLK;
        },
        .fifo, .ext_fifo => mode = std.posix.DT.FIFO,
        .socket, .ext_socket => mode = std.posix.DT.SOCK,
        else => unreachable,
    }

    const sentinel_path = try std.mem.concatMaybeSentinel(alloc, u8, &[1][]const u8{path}, 0);
    defer alloc.free(sentinel_path);
    const res = std.os.linux.mknod(sentinel_path, mode, dev);
    if (res != 0 and options.verbose)
        options.verbose_writer.?.print("mknod failed with code: {}\n", .{res}) catch {};

    try que.putOne(io, .{
        .file = try Io.Dir.cwd().openFile(io, path, .{}),
        .inode = self,
    });
}

fn applyMetadataLoop(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *const Decompressor, super: Archive.Superblock, que: *Io.Queue(FileRet), options: ExtractionOptions) !void {
    var id_table: LookupTable.CachedTable(u16) = .init(alloc, fil, decomp, super.id_start, super.id_count);
    defer id_table.deinit(io);
    var xattr_table: XattrTable = try .init(alloc, io, fil, decomp, super.xattr_start);
    defer xattr_table.deinit(io);
    for (try que.getOne(io)) |ret| {
        const inode: Inode = ret.inode;
        defer inode.deinit(alloc);
        const ret_file: Io.File = ret.file;
        defer ret_file.close(io);

        if (!options.ignore_xattr) {
            if (inode.xattrIndex()) |idx| {
                const xattrs = try xattr_table.get(io, idx);
                for (xattrs) |x| {
                    // TODO: Check error.
                    _ = std.os.linux.fsetxattr(ret_file.handle, x.key, x.value.ptr, x.value.len, 0);
                }
            }
        }
        if (!options.ignore_permissions) {
            try ret_file.setPermissions(io, inode.hdr.permissions);
            try ret_file.setOwner(io, try id_table.get(io, inode.hdr.uid_idx), try id_table.get(io, inode.hdr.gid_idx));
        }
    }
}

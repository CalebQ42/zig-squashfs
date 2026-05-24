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
pub fn readDirectory(self: Inode, alloc: std.mem.Allocator, fil: OffsetFile, decomp: *Decompressor, dir_offset: u64) ![]DirEntry {
    return switch (self.data) {
        .dir => |d| readDirFromData(alloc, fil, decomp, dir_offset, d),
        .ext_dir => |d| readDirFromData(alloc, fil, decomp, dir_offset, d),
        else => Error.NotDirectory,
    };
}
fn readDirFromData(alloc: std.mem.Allocator, fil: OffsetFile, decomp: *Decompressor, dir_offset: u64, d: anytype) ![]DirEntry {
    var rdr = fil.readerAt(dir_offset + d.block_start);
    var meta: MetadataReader = .init(alloc, &rdr, decomp);
    try meta.interface.discardAll(d.block_offset);

    return DirEntry.readDirectory(alloc, &meta.interface, d.size);
}
/// Get a reader for a regular file's data.
pub fn dataReader(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, block_size: u32, frag_block: ?[]u8) !DataReader {
    return switch (self.data) {
        .file => |f| getReaderFromData(alloc, io, fil, decomp, block_size, frag_block, f),
        .ext_file => |f| getReaderFromData(alloc, io, fil, decomp, block_size, frag_block, f),
        else => Error.NotRegularFile,
    };
}
fn getReaderFromData(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, block_size: u32, frag_block: ?[]u8, d: anytype) !DataReader {
    const ext: DataReader = .init(alloc, io, fil, decomp, block_size, d.size, d.block_start, d.blocks);
    if (d.frag_block_offset == 0xFFFFFFFF) {
        if (frag_block == null) return error.FragBlockNotProvided;
        ext.addFrag(d.frag_block_offset, frag_block.?);
    }
    return ext;
}
/// Get an extractor for a regular file's data.
pub fn dataExtractor(self: Inode, fil: OffsetFile, decomp: *Decompressor, block_size: u32, frag_block: ?[]u8) !DataExtractor {
    return switch (self.data) {
        .file => |f| getExtractorFromData(fil, decomp, block_size, frag_block, f),
        .ext_file => |f| getExtractorFromData(fil, decomp, block_size, frag_block, f),
        else => Error.NotRegularFile,
    };
}
fn getExtractorFromData(fil: OffsetFile, decomp: *Decompressor, block_size: u32, frag_block: ?[]u8, d: anytype) !DataExtractor {
    const ext: DataExtractor = .init(fil, decomp, block_size, d.size, d.block_start, d.blocks);
    if (d.frag_block_offset == 0xFFFFFFFF) {
        if (frag_block == null) return error.FragBlockNotProvided;
        ext.addFrag(d.frag_block_offset, frag_block.?);
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
pub fn gid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, id_table_start: u64) !u16 {
    return LookupTable.lookupValue(u16, alloc, io, decomp, fil, id_table_start, self.hdr.gid_idx);
}
/// Get inode's uid
pub fn uid(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, id_table_start: u64) !u16 {
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
        else => return error.NoXattr,
    };
    if (idx == 0xFFFFFFFF) return error.NoXattr;
    return idx;
}
// Get an inode's xattr values. If the inode does not have xattr values (including if the inode is not an extended type), an empty slice is returned.
pub fn xattrValues(self: Inode, alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, xattr_table_start: u64) ![]XattrTable.XattrOwned {
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

const ExtractError = error{ MknodFailed, CannotSetXattr } || DataExtractor.Error || DirEntry.Error ||
    Decompressor.Error || Io.File.Atomic.InitError || Io.File.Atomic.LinkError || Io.Dir.SymLinkError;
const PathRet = struct {
    path: []const u8,
    inode: Inode,
    origin: bool,

    fn deinit(self: PathRet, alloc: std.mem.Allocator) void {
        if (self.origin) return;
        alloc.free(self.path);
        self.inode.deinit(alloc);
    }
    fn setMetadata(self: PathRet, alloc: std.mem.Allocator, io: Io, id_table: *CachedTable(u16), xattr_table: ?*XattrTable, options: ExtractionOptions) !void {
        var fil = try Io.Dir.cwd().openFile(io, self.path, .{});
        defer fil.close(io);

        const inode = self.inode;

        if (!options.ignore_permissions) {
            try fil.setPermissions(io, @enumFromInt(inode.hdr.permissions));
            try fil.setOwner(io, try id_table.get(io, inode.hdr.uid_idx), try id_table.get(io, inode.hdr.gid_idx));
        }
        if (xattr_table != null) {
            const idx = inode.xattrIndex() catch return;

            const xattrs = try xattr_table.?.get(alloc, io, idx);
            defer {
                for (xattrs) |x|
                    x.deinit(alloc);
                alloc.free(xattrs);
            }

            const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{self.path}, 0);
            defer alloc.free(sentinel_path);
            for (xattrs) |x| {
                const xattr_ret = std.os.linux.fsetxattr(fil.handle, x.key, x.value.ptr, x.value.len, 0);
                if (xattr_ret != 0)
                    return ExtractError.CannotSetXattr;
            }
        }
    }
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
    const path = std.mem.trimEnd(u8, filepath, "/");

    var decomp_base: Decompressor = try @import("decomp.zig").StatelessDecomp(super.compression); // TODO: Replace with actual Decomp value to share states & caches for efficiency.
    const decomp = &decomp_base;

    var frag_mgr: FragManager = try .init(alloc, fil, decomp, super.frag_start, super.frag_count, super.block_size);
    defer frag_mgr.deinit(io);

    if (options.single_threaded)
        return self.extractSinglethreaded(alloc, io, fil, super, path, options, decomp, &frag_mgr);

    var sel_buf: [10]ExtractReturnUnion = undefined;
    var sel: Io.Select(ExtractReturnUnion) = .init(io, &sel_buf);
    defer sel.cancelDiscard();

    var loop = io.async(finishLoop, .{ alloc, io, fil, decomp, super, options, &sel });

    sel.async(.path_ret, extractRealAsync, .{ self, alloc, io, fil, super, decomp, &sel, &frag_mgr, path, true });

    try loop.await(io);
}
fn extractRealAsync(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    super: Archive.Superblock,
    decomp: *Decompressor,
    sel: *Io.Select(ExtractReturnUnion),
    frag_mgr: *FragManager,
    path: []const u8,
    origin: bool,
) ExtractError!PathRet {
    errdefer {
        if (!origin) {
            self.deinit(alloc);
            alloc.free(path);
        }
    }
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            try Io.Dir.cwd().createDir(io, path, @enumFromInt(0o777));

            const entries = self.readDirectory(alloc, fil, decomp, super.dir_start) catch |err| switch (err) {
                Error.NotDirectory, Error.NotExtended, Error.NotRegularFile, Error.NotSymlink => unreachable,
                else => |e| return e,
            };
            defer {
                for (entries) |e|
                    e.deinit(alloc);
                alloc.free(entries);
            }

            for (entries) |e| {
                const new_path = try std.mem.concat(alloc, u8, &[_][]const u8{ path, "/", e.name });
                errdefer alloc.free(new_path);

                var rdr = fil.readerAt(super.inode_start + e.block_start);
                var meta: MetadataReader = .init(alloc, &rdr, decomp);
                try meta.interface.discardAll(e.block_offset);

                const new_inode = try read(alloc, &meta.interface, super.block_size);
                errdefer new_inode.deinit(alloc);

                sel.async(.path_ret, extractRealAsync, .{ new_inode, alloc, io, fil, super, decomp, sel, frag_mgr, new_path, false });
            }
        },
        .file, .ext_file => {
            var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
            defer atomic.deinit(io);

            var ext: DataExtractor = switch (self.data) {
                .file => |f| blk: {
                    var ext: DataExtractor = .init(fil, decomp, super.block_size, f.size, f.block_start, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF)
                        ext.addFrag(f.frag_block_offset, try frag_mgr.get(io, f.frag_idx));
                    break :blk ext;
                },
                .ext_file => |f| blk: {
                    var ext: DataExtractor = .init(fil, decomp, super.block_size, f.size, f.block_start, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF)
                        ext.addFrag(f.frag_block_offset, try frag_mgr.get(io, f.frag_idx));
                    break :blk ext;
                },
                else => unreachable,
            };

            try ext.extractAsync(alloc, io, atomic.file);

            try atomic.link(io);
        },
        .symlink, .ext_symlink => try Io.Dir.cwd().symLink(io, self.symlinkTarget() catch unreachable, path, .{}),
        else => {
            var mode: u32 = undefined;
            var dev: u32 = 0;

            const DT = std.posix.DT;

            switch (self.data) {
                .char_dev => |d| {
                    dev = d.dev;
                    mode = DT.CHR;
                },
                .ext_char_dev => |d| {
                    dev = d.dev;
                    mode = DT.CHR;
                },
                .block_dev => |d| {
                    dev = d.dev;
                    mode = DT.BLK;
                },
                .ext_block_dev => |d| {
                    dev = d.dev;
                    mode = DT.BLK;
                },
                .fifo, .ext_fifo => mode = DT.FIFO,
                .socket, .ext_socket => mode = DT.SOCK,
                else => unreachable,
            }

            const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{path}, 0);
            const res = std.os.linux.mknod(sentinel_path, mode, dev);
            alloc.free(sentinel_path);
            if (res != 0)
                return ExtractError.MknodFailed;
        },
    }
    return .{
        .path = path,
        .inode = self,
        .origin = origin,
    };
}
fn finishLoop(alloc: std.mem.Allocator, io: Io, fil: OffsetFile, decomp: *Decompressor, super: Archive.Superblock, options: ExtractionOptions, sel: *Io.Select(ExtractReturnUnion)) !void {
    var id_table: CachedTable(u16) = .init(alloc, fil, decomp, super.id_start, super.id_count);
    defer id_table.deinit(io);

    var xattr_table: ?XattrTable = if (super.flags.xattr_never or options.ignore_xattr or !@hasField(std.os, "linux"))
        null
    else
        try .init(alloc, fil, decomp, super.xattr_start);
    defer if (xattr_table != null) xattr_table.?.deinit(io);

    var dir_queue: std.PriorityDequeue(PathRet, void, DirCompare) = .empty;
    defer dir_queue.deinit(alloc);

    while (true) {
        if (sel.group.token.load(.unordered) == null) break;

        const ret = try sel.await();
        const path_ret = try ret.path_ret;

        if (options.ignore_permissions and xattr_table == null) {
            path_ret.deinit(alloc);
            continue;
        }

        if (path_ret.inode.hdr.inode_type == .dir or path_ret.inode.hdr.inode_type == .ext_dir) {
            try dir_queue.push(alloc, path_ret);
            continue;
        }
        defer path_ret.deinit(alloc);

        try path_ret.setMetadata(alloc, io, &id_table, if (xattr_table == null) null else &xattr_table.?, options);
    }

    while (sel.cancel()) |ret| {
        const path_ret = try ret.path_ret;

        if (options.ignore_permissions and xattr_table == null) {
            path_ret.deinit(alloc);
            continue;
        }

        if (path_ret.inode.hdr.inode_type == .dir or path_ret.inode.hdr.inode_type == .ext_dir) {
            try dir_queue.push(alloc, path_ret);
            continue;
        }

        defer path_ret.deinit(alloc);
        try path_ret.setMetadata(alloc, io, &id_table, if (xattr_table == null) null else &xattr_table.?, options);
    }

    var iter = dir_queue.iterator();
    while (iter.next()) |path_ret| {
        defer path_ret.deinit(alloc);
        try path_ret.setMetadata(alloc, io, &id_table, if (xattr_table == null) null else &xattr_table.?, options);
    }
}
/// Extracts the given inode to the given path. If the inode not a directory, the given path must not exist.
/// If the inode is a directory the path must not exist or be a directory.
fn extractSinglethreaded(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    super: Archive.Superblock,
    path: []const u8,
    options: ExtractionOptions,
    decomp: *Decompressor,
    frag: *FragManager,
) !void {
    var id_table: CachedTable(u16) = .init(alloc, fil, decomp, super.id_start, super.id_count);
    defer id_table.deinit(io);

    var xattr_table: ?XattrTable = if (super.flags.xattr_never or options.ignore_xattr or !@hasField(std.os, "linux"))
        null
    else
        try .init(alloc, fil, decomp, super.xattr_start);
    defer if (xattr_table != null) xattr_table.?.deinit(io);

    return self.extractReal(
        alloc,
        io,
        fil,
        super,
        decomp,
        frag,
        &id_table,
        if (xattr_table == null) null else &xattr_table.?,
        path,
        options,
    );
}
fn extractReal(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    fil: OffsetFile,
    super: Archive.Superblock,
    decomp: *Decompressor,
    frag_mgr: *FragManager,
    id_table: *CachedTable(u16),
    xattr_table: ?*XattrTable,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            try Io.Dir.cwd().createDir(io, path, @enumFromInt(0o777));

            const entries = self.readDirectory(alloc, fil, decomp, super.dir_start) catch |err| switch (err) {
                Error.NotDirectory, Error.NotExtended, Error.NotRegularFile, Error.NotSymlink => unreachable,
                else => |e| return e,
            };
            defer {
                for (entries) |e|
                    e.deinit(alloc);
                alloc.free(entries);
            }

            for (entries) |e| {
                const new_path = try std.mem.concat(alloc, u8, &[_][]const u8{ path, "/", e.name });
                defer alloc.free(new_path);

                var rdr = fil.readerAt(super.inode_start + e.block_start);
                var meta: MetadataReader = .init(alloc, &rdr, decomp);
                try meta.interface.discardAll(e.block_offset);

                const new_inode = try read(alloc, &meta.interface, super.block_size);
                defer new_inode.deinit(alloc);

                try new_inode.extractReal(alloc, io, fil, super, decomp, frag_mgr, id_table, xattr_table, new_path, options);
            }
        },
        .file, .ext_file => {
            var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
            defer atomic.deinit(io);

            var rdr: DataReader = switch (self.data) {
                .file => |f| blk: {
                    var ext: DataReader = try .init(alloc, io, fil, decomp, super.block_size, f.size, f.block_start, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF)
                        ext.addFrag(f.frag_block_offset, try frag_mgr.get(io, f.frag_idx));
                    break :blk ext;
                },
                .ext_file => |f| blk: {
                    var ext: DataReader = try .init(alloc, io, fil, decomp, super.block_size, f.size, f.block_start, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF)
                        ext.addFrag(f.frag_block_offset, try frag_mgr.get(io, f.frag_idx));
                    break :blk ext;
                },
                else => unreachable,
            };
            defer rdr.deinit();

            var buf: [512 * 1024]u8 = undefined;
            var wrt = atomic.file.writer(io, &buf);

            _ = try rdr.interface.streamRemaining(&wrt.interface);

            try wrt.flush();

            try atomic.link(io);
        },
        .symlink, .ext_symlink => try Io.Dir.cwd().symLink(io, self.symlinkTarget() catch unreachable, path, .{}),
        else => {
            var mode: u32 = undefined;
            var dev: u32 = 0;

            const DT = std.posix.DT;

            switch (self.data) {
                .char_dev => |d| {
                    dev = d.dev;
                    mode = DT.CHR;
                },
                .ext_char_dev => |d| {
                    dev = d.dev;
                    mode = DT.CHR;
                },
                .block_dev => |d| {
                    dev = d.dev;
                    mode = DT.BLK;
                },
                .ext_block_dev => |d| {
                    dev = d.dev;
                    mode = DT.BLK;
                },
                .fifo, .ext_fifo => mode = DT.FIFO,
                .socket, .ext_socket => mode = DT.SOCK,
                else => unreachable,
            }

            const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{path}, 0);
            const res = std.os.linux.mknod(sentinel_path, mode, dev);
            alloc.free(sentinel_path);
            if (res != 0)
                return ExtractError.MknodFailed;
        },
    }
    if (options.ignore_permissions and options.ignore_xattr) return;

    var f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);

    if (!options.ignore_permissions) {
        try f.setPermissions(io, @enumFromInt(self.hdr.permissions));
        try f.setOwner(io, try id_table.get(io, self.hdr.uid_idx), try id_table.get(io, self.hdr.gid_idx));
    }
    if (xattr_table != null) {
        const idx = self.xattrIndex() catch return;

        const xattrs = try xattr_table.?.get(alloc, io, idx);
        defer {
            for (xattrs) |x|
                x.deinit(alloc);
            alloc.free(xattrs);
        }

        const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &[_][]const u8{path}, 0);
        defer alloc.free(sentinel_path);
        for (xattrs) |x| {
            const xattr_ret = std.os.linux.fsetxattr(f.handle, x.key, x.value.ptr, x.value.len, 0);
            if (xattr_ret != 0)
                return ExtractError.CannotSetXattr;
        }
    }
}

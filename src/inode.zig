//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const WaitGroup = std.Thread.WaitGroup;
const Pool = std.Thread.Pool;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const DataReader = @import("util/data.zig");
const MetadataReader = @import("util/metadata.zig");

pub const Ref = packed struct {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const InodeType = enum(u16) {
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

pub const InodeData = union(InodeType) {
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

pub const Header = packed struct {
    inode_type: InodeType,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

const Inode = @This();

hdr: Header,
data: InodeData,

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
        .file => |f| alloc.free(f.block_sizes),
        .ext_file => |f| alloc.free(f.block_sizes),
        .symlink => |s| alloc.free(s.target),
        .ext_symlink => |s| alloc.free(s.target),
        else => {},
    }
}

/// Get the data reader for a file inode.
pub fn dataReader(self: Inode, archive: *Archive) !DataReader {
    return switch (self.hdr.inode_type) {
        .file => readerFromData(archive, self.data.file),
        .ext_file => readerFromData(archive, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn readerFromData(archive: *Archive, data: anytype) !DataReader {
    var out: DataReader = .init(archive, data.block_sizes, data.block_start, data.size);
    if (data.frag_idx != 0xFFFFFFFF)
        out.addFragment(try archive.frag(data.frag_idx), data.frag_block_offset);
    return out;
}

/// Get the directory entries for a directory inode.
pub fn dirEntries(self: Inode, archive: *Archive) ![]DirEntry {
    return switch (self.hdr.inode_type) {
        .dir => entriesFromData(archive, self.data.dir),
        .ext_dir => entriesFromData(archive, self.data.ext_dir),
        else => error.NotDirectory,
    };
}
fn entriesFromData(archive: *Archive, data: anytype) ![]DirEntry {
    var rdr = try archive.fil.readerAt(archive.super.dir_start + data.block_start, &[0]u8{});
    const alloc = archive.allocator();
    var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
    try meta.interface.discardAll(data.block_offset);
    return DirEntry.readDir(alloc, &meta.interface, data.size);
}

pub fn extractTo(self: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            // Removing any trailing separators since that's the easiest path forward.
            if (path[path.len - 1] == '/') return self.extractTo(archive, path[0 .. path.len - 1], options);
            std.fs.cwd().makeDir(path) catch |err| {
                if (err != std.fs.Dir.MakeError.PathAlreadyExists) return err;
            };
            var alloc = archive.allocator();
            const entries = try self.dirEntries(archive);
            defer {
                for (entries) |entry| entry.deinit(alloc);
                alloc.free(entries);
            }
            for (entries) |entry| {
                var new_path = try alloc.alloc(u8, path.len + 1 + entry.name.len);
                @memcpy(new_path[0..path.len], path);
                @memcpy(new_path[path.len + 1 ..], entry.name);
                new_path[path.len] = '/';
                defer alloc.free(new_path);

                var rdr = try archive.fil.readerAt(archive.super.inode_start + entry.block_start, &[0]u8{});
                var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
                try meta.interface.discardAll(entry.block_offset);
                var inode: Inode = try read(alloc, &meta.interface, archive.super.block_size);
                defer inode.deinit(alloc);
                try inode.extractTo(archive, new_path, options);
            }
        },
        .file, .ext_file => try self.extractRegFile(archive, path, options),
        .symlink, .ext_symlink => try self.extractSymlink(path),
        else => try self.extractDevice(archive, path, options),
    }
}

const Perms = struct {
    path: []const u8,
    owner: u16,
    perm: u16,
    mod_time: u32,
};

pub fn extractToThreaded(inode: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions, threads: usize) !void {
    _ = archive;
    _ = path;
    _ = options;
    _ = threads;
    switch (inode.hdr.inode_type) {}
}

/// Extract threadedly the inode to the path.
fn extractThread(inode: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions, wg: *WaitGroup, pool: *Pool, perms: ?*std.ArrayList(Perms)) !void {
    _ = pool;
    _ = perms;
    _ = archive;
    switch (inode.hdr.inode_type) {
        .dir, .ext_dir => {
            //TOOD
            return error.TODO;
        },
        .file, .ext_file => {
            //TOOD
            return error.TODO;
        },
        .symlink, .ext_symlink => {
            defer wg.finish();
            try inode.extractSymlink(path);
        },
        else => {
            defer wg.finish();
            try inode.extractDevice(path, options.ignore_permissions);
        },
    }
}
/// Creates and writes the inode file contents to the given path.
/// Optionally set owner & permissions.
///
/// Assumes the inode is a file or ext_file type.
fn extractRegFile(self: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    var fil = try std.fs.cwd().createFile(path, .{});
    defer fil.close();
    var buf: [8192]u8 = undefined;
    var wrt = fil.writer(&buf);
    var dat_rdr = try self.dataReader(archive);
    defer dat_rdr.deinit();
    _ = try dat_rdr.interface.streamRemaining(&wrt.interface);
    try wrt.interface.flush();
    // updateTime is in nanoseconds (a billionth of a second). mod_time is in seconds.
    try fil.updateTimes(self.hdr.mod_time, self.hdr.mod_time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id(self.hdr.uid_idx), try archive.id(self.hdr.gid_idx));
    }
    if (!options.ignore_xattr) {
        // TODO
    }
}
/// TODO: not implemented
/// Extract the inode file contents to the given path.
/// The extraction will be done threaded using pool for threads and will call wg.finish() when done.
///
/// Optionally set owner & permissions.
/// Assumes the inode is a file or ext_file type.
fn extractRegFileThreaded(self: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions, pool: *Pool, wg: *WaitGroup) !void {
    _ = self;
    _ = archive;
    _ = path;
    _ = options;
    _ = pool;
    _ = wg;
    return error.TODO;
}
/// Creates the symlink described by the inode.
///
/// Assumes the inode is a symlink or ext_symlink type.
fn extractSymlink(self: Inode, path: []const u8) !void {
    const target = switch (self.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };
    try std.fs.cwd().symLink(target, path, .{});
}
/// Creates the device described by the inode.
///
/// Optionally set owner & permissions.
/// Assumes the inode is a char_dev, block_dev, fifo, socket, or their extended counterparts.
fn extractDevice(self: Inode, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    var mode: u32 = undefined;
    var dev: u32 = 0;
    switch (self.data) {
        .char_dev => |d| {
            mode = std.posix.S.IFCHR;
            dev = d.dev;
        },
        .ext_char_dev => |d| {
            mode = std.posix.S.IFCHR;
            dev = d.dev;
        },
        .block_dev => |d| {
            mode = std.posix.S.IFBLK;
            dev = d.dev;
        },
        .ext_block_dev => |d| {
            mode = std.posix.S.IFBLK;
            dev = d.dev;
        },
        .fifo, .ext_fifo => mode = std.posix.S.IFIFO,
        .socket, .ext_socket => mode = std.posix.S.IFSOCK,
        else => unreachable,
    }
    const res: std.os.linux.E = @enumFromInt(std.os.linux.mknod(@ptrCast(path), mode, dev));
    switch (res) {
        .SUCCESS => {},
        .ACCES => return std.fs.Dir.MakeError.AccessDenied,
        .DQUOT => return std.fs.Dir.MakeError.DiskQuota,
        .EXIST => return std.fs.Dir.MakeError.PathAlreadyExists,
        .FAULT, .NOENT => return std.fs.Dir.MakeError.BadPathName,
        .LOOP => return std.fs.Dir.MakeError.SymLinkLoop,
        .NAMETOOLONG => return std.fs.Dir.MakeError.NameTooLong,
        .NOMEM => return std.fs.Dir.MakeError.SystemResources,
        .NOSPC => return std.fs.Dir.MakeError.NoSpaceLeft,
        .NOTDIR => return std.fs.Dir.MakeError.NotDir,
        .PERM => return std.fs.Dir.MakeError.PermissionDenied,
        .ROFS => return std.fs.Dir.MakeError.ReadOnlyFileSystem,
        else => return blk: {
            std.debug.print("unhandled mknod result: {}\n", .{res});
            break :blk std.fs.Dir.MakeError.Unexpected;
        },
    }
    var fil = try std.fs.cwd().openFile(path, .{});
    // updateTime is in nanoseconds (a billionth of a second). mod_time is in seconds.
    try fil.updateTimes(self.hdr.mod_time * (10 ^ 9), self.hdr.mod_time * (10 ^ 9));
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id(self.hdr.uid_idx), try archive.id(self.hdr.gid_idx));
    }
    if (!options.ignore_xattr) {
        // TODO
    }
}

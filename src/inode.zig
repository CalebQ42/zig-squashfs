//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const WaitGroup = std.Thread.WaitGroup;
const Pool = std.Thread.Pool;
const Mutex = std.Thread.Mutex;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const DataReader = @import("util/data.zig");
const ThreadedDataReader = @import("util/data_threaded.zig");
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
pub fn readFromEntry(alloc: std.mem.Allocator, archive: Archive, entry: DirEntry) !Inode {
    var rdr = try archive.fil.readerAt(archive.super.inode_start + entry.block_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
    try meta.interface.discardAll(entry.block_offset);
    return read(alloc, &meta.interface, archive.super.block_size);
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
pub fn dataReader(self: Inode, alloc: std.mem.Allocator, archive: Archive) !DataReader {
    return switch (self.hdr.inode_type) {
        .file => readerFromData(alloc, archive, self.data.file),
        .ext_file => readerFromData(alloc, archive, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn readerFromData(alloc: std.mem.Allocator, archive: Archive, data: anytype) !DataReader {
    return .init(
        alloc,
        archive,
        data.block_sizes,
        data.block_start,
        data.size,
        data.frag_block_offset,
        if (data.frag_idx == 0xFFFFFFFF) null else try archive.frag_table.get(alloc, data.frag_idx),
    );
}
/// Get a threaded data reader for a file inode.
pub fn threadedDataReader(self: Inode, alloc: std.mem.Allocator, archive: Archive) !ThreadedDataReader {
    return switch (self.hdr.inode_type) {
        .file => threadedReaderFromData(alloc, archive, self.data.file),
        .ext_file => threadedReaderFromData(alloc, archive, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn threadedReaderFromData(alloc: std.mem.Allocator, archive: Archive, data: anytype) !ThreadedDataReader {
    return .init(
        alloc,
        archive,
        data.block_sizes,
        data.block_start,
        data.size,
        data.frag_block_offset,
        if (data.frag_idx == 0xFFFFFFFF) null else try archive.frag_table.get(alloc, data.frag_idx),
    );
}

/// Get the directory entries for a directory inode.
pub fn dirEntries(self: Inode, alloc: std.mem.Allocator, archive: Archive) ![]DirEntry {
    return switch (self.hdr.inode_type) {
        .dir => entriesFromData(alloc, archive, self.data.dir),
        .ext_dir => entriesFromData(alloc, archive, self.data.ext_dir),
        else => error.NotDirectory,
    };
}
fn entriesFromData(alloc: std.mem.Allocator, archive: Archive, data: anytype) ![]DirEntry {
    var rdr = try archive.fil.readerAt(archive.super.dir_start + data.block_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
    try meta.interface.discardAll(data.block_offset);
    return DirEntry.readDir(alloc, &meta.interface, data.size);
}

/// Extract the inode to the given path.
pub fn extractTo(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions) !void {
    if (options.threads > 1) return self.extractToThreaded(alloc, archive, path, options); // We go to a dedicated function for mutli-threaded
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            // Removing any trailing separators since that's the easiest path forward.
            if (path[path.len - 1] == '/') return self.extractTo(alloc, archive, path[0 .. path.len - 1], options);
            std.fs.cwd().makeDir(path) catch |err| {
                if (err != std.fs.Dir.MakeError.PathAlreadyExists) return err;
            };
            const entries = try self.dirEntries(alloc, archive);
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

                var inode: Inode = try readFromEntry(alloc, archive, entry);
                defer inode.deinit(alloc);
                try inode.extractTo(alloc, archive, new_path, options);
            }
        },
        .file, .ext_file => try self.extractRegFile(alloc, archive, path, options),
        .symlink, .ext_symlink => try self.extractSymlink(path),
        else => try self.extractDevice(alloc, archive, path, options),
    }
}

const Parent = struct {
    alloc: std.mem.Allocator,

    path: []const u8,
    uid: u16,
    gid: u16,
    perm: u16,
    mod_time: u32,

    ignore_permissions: bool,
    ignore_xattr: bool,

    wg: WaitGroup,
    mut: Mutex = .{},

    fn create(alloc: std.mem.Allocator, hdr: Header, archive: Archive, path: []const u8, options: ExtractionOptions, dir_size: usize) !*Parent {
        const out = try alloc.create(Parent);
        errdefer alloc.destroy(out);
        out.* = .{
            .alloc = alloc,

            .path = path,
            .uid = try archive.id_table.get(alloc, hdr.uid_idx),
            .gid = try archive.id_table.get(alloc, hdr.gid_idx),
            .perm = hdr.permissions,
            .mod_time = hdr.mod_time,

            .ignore_permissions = options.ignore_permissions,
            .ignore_xattr = options.ignore_xattr,

            .wg = .{},
        };
        out.wg.startMany(dir_size);
        return out;
    }

    fn finish(p: *Parent) !void {
        p.mut.lock();
        {
            defer p.mut.unlock();
            p.wg.finish();
            if (!p.wg.isDone()) return;
        }
        defer p.alloc.destroy(p);
        var fil = try std.fs.cwd().openFile(p.path, .{});
        defer fil.close();
        const time = @as(i128, p.mod_time) * 1000000000;
        try fil.updateTimes(time, time);
        if (p.ignore_permissions) {
            try fil.chmod(p.perm);
            try fil.chown(p.uid, p.gid);
        }
    }
};

/// Extract the inode to the given path. Multi-threaded.
/// Functions identically to extractTo on all but regular files and directories.
fn extractToThreaded(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions) !void {
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            // Removing any trailing separators since that's the easiest path forward.
            if (path[path.len - 1] == '/') return self.extractToThreaded(alloc, archive, path[0 .. path.len - 1], options);

            // Arena Allocator
            var arena_alloc: std.heap.ArenaAllocator = .init(alloc);
            defer arena_alloc.deinit();
            var thread_alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = arena_alloc.allocator() };

            var wg: WaitGroup = .{};
            // defer if(!options.ignore_permissions) perms.?.deinit(alloc); We don't need to do this due to ArenaAllocator
            var pool: Pool = undefined;
            try pool.init(.{ .allocator = alloc, .n_jobs = options.threads - 1 });
            defer pool.deinit();
            var out_err: ?anyerror = null;

            wg.start();
            self.extractThread(thread_alloc.allocator(), archive, path, options, &wg, &pool, &out_err, null);
            pool.waitAndWork(&wg);
            if (out_err != null) return out_err.?;

            var fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            const time = @as(i128, self.hdr.mod_time) * 1000000000;
            try fil.updateTimes(time, time);
            if (options.ignore_permissions) {
                try fil.chmod(self.hdr.permissions);
                try fil.chown(try archive.id_table.get(alloc, self.hdr.uid_idx), try archive.id_table.get(alloc, self.hdr.gid_idx));
            }
        },
        .file, .ext_file => {
            var pool: Pool = undefined;
            try pool.init(.{ .allocator = alloc, .n_jobs = options.threads - 1 });
            defer pool.deinit();

            var thread_alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = alloc };

            try self.extractRegFileThreaded(thread_alloc.allocator(), archive, path, options, &pool);

            var fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            const time = @as(i128, self.hdr.mod_time) * 1000000000;
            try fil.updateTimes(time, time);
            if (!options.ignore_permissions) {
                try fil.chmod(self.hdr.permissions);
                try fil.chown(try archive.id_table.get(alloc, self.hdr.uid_idx), try archive.id_table.get(alloc, self.hdr.gid_idx));
            }
        },
        .symlink, .ext_symlink => try self.extractSymlink(path),
        else => try self.extractDevice(alloc, archive, path, options),
    }
}

fn extractThreadEntry(
    entry: DirEntry,
    alloc: std.mem.Allocator,
    archive: Archive,
    path: []const u8,
    options: ExtractionOptions,
    wg: *WaitGroup,
    pool: *Pool,
    out_err: *?anyerror,
    parent: ?*Parent,
) void {
    var new_path = alloc.alloc(u8, path.len + entry.name.len + 1) catch |err| {
        wg.finish();
        out_err.* = err;
        return;
    };
    @memcpy(new_path[0..path.len], path);
    @memcpy(new_path[path.len + 1 ..], entry.name);
    new_path[path.len] = '/';
    var inode = readFromEntry(alloc, archive, entry) catch |err| {
        out_err.* = err;
        wg.finish();
        return;
    };
    inode.extractThread(alloc, archive, new_path, options, wg, pool, out_err, parent);
}

/// Extract threadedly the inode to the path.
fn extractThread(
    self: Inode,
    alloc: std.mem.Allocator,
    archive: Archive,
    path: []const u8,
    options: ExtractionOptions,
    wg: *WaitGroup,
    pool: *Pool,
    out_err: *?anyerror,
    parent: ?*Parent,
) void {
    if (options.verbose)
        options.verbose_writer.?.print("Extracting inode #{} to {s}\n", .{ self.hdr.num, path }) catch {};
    defer {
        if (parent != null) parent.?.finish() catch |err| {
            if (options.verbose)
                options.verbose_writer.?.print("Error setting folder permission to {s}: {}\n", .{ parent.?.path, err }) catch {};
            out_err.* = err;
        };
        wg.finish();
    }
    if (out_err.* != null) return;
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            _ = std.fs.cwd().makePathStatus(path) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error creating {s}: {}\n", .{ path, err }) catch {};
                out_err.* = err;
                return;
            };

            const entries = self.dirEntries(alloc, archive) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error getting directory entries for inode #{} (extracting to {s}): {}\n", .{ self.hdr.num, path, err }) catch {};
                out_err.* = err;
                return;
            };
            const p = Parent.create(alloc, self.hdr, archive, path, options, entries.len) catch |err| {
                out_err.* = err;
                return;
            };
            wg.startMany(entries.len);
            // defer files.deinit(alloc); We don't need to do this due to ArenaAllocator
            for (entries) |entry| {
                if (entry.inode_type == .dir) {
                    extractThreadEntry(entry, alloc, archive, path, options, wg, pool, out_err, p);
                    continue;
                }
                pool.spawn(
                    extractThreadEntry,
                    .{
                        entry,
                        alloc,
                        archive,
                        path,
                        options,
                        wg,
                        pool,
                        out_err,
                        p,
                    },
                ) catch |err| {
                    wg.finish();
                    p.finish() catch |e| {
                        if (options.verbose)
                            options.verbose_writer.?.print("Error setting folder permission to {s}: {}\n", .{ p.path, e }) catch {};
                    };
                    if (options.verbose)
                        options.verbose_writer.?.print("Error starting extraction thread: {}\n", .{err}) catch {};
                    out_err.* = err;
                    continue;
                };
            }
        },
        .file, .ext_file => {
            self.extractRegFileThreaded(alloc, archive, path, options, pool) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error extracting file inode #{} to {s}: {}\n", .{ self.hdr.num, path, err }) catch {};
                out_err.* = err;
            };
        },
        .symlink, .ext_symlink => {
            self.extractSymlink(path) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error extracting symlink inode #{} to {s}: {}\n", .{ self.hdr.num, path, err }) catch {};
                out_err.* = err;
            };
        },
        else => {
            self.extractDevice(alloc, archive, path, options) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error extracting device/IPC inode #{} to {s}: {}\n", .{ self.hdr.num, path, err }) catch {};
                out_err.* = err;
            };
        },
    }
}
/// Creates and writes the inode file contents to the given path.
/// Optionally set owner & permissions.
///
/// Assumes the inode is a file or ext_file type.
fn extractRegFile(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions) !void {
    var fil = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer fil.close();
    var wrt = fil.writer(&[0]u8{});
    var dat_rdr = try self.dataReader(alloc, archive);
    defer dat_rdr.deinit();
    _ = try dat_rdr.interface.streamRemaining(&wrt.interface);
    try wrt.interface.flush();

    const time = @as(i128, self.hdr.mod_time) * 1000000000;
    try fil.updateTimes(time, time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id_table.get(alloc, self.hdr.uid_idx), try archive.id_table.get(alloc, self.hdr.gid_idx));
    }
}
/// Extract the inode file contents to the given path threadedly.
/// pool is used to spawn threads.
///
/// Assumes the inode is a file or ext_file type.
fn extractRegFileThreaded(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions, pool: *Pool) !void {
    var fil = try std.fs.cwd().createFile(path, .{});
    defer fil.close();
    var data = try self.threadedDataReader(alloc, archive);
    try data.extractThreaded(fil, pool);

    const time = @as(i128, self.hdr.mod_time) * 1000000000;
    try fil.updateTimes(time, time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id_table.get(alloc, self.hdr.uid_idx), try archive.id_table.get(alloc, self.hdr.gid_idx));
    }
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
fn extractDevice(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions) !void {
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
    defer fil.close();
    const time = @as(i128, self.hdr.mod_time) * 1000000000;
    try fil.updateTimes(time, time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id_table.get(alloc, self.hdr.uid_idx), try archive.id_table.get(alloc, self.hdr.gid_idx));
    }
    if (!options.ignore_xattr) {
        // TODO
    }
}

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
const InodeFinish = @import("util/inode_finish.zig");
const FinishUnion = InodeFinish.FinishUnion;
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
pub fn readFromEntry(alloc: std.mem.Allocator, archive: *Archive, entry: DirEntry) !Inode {
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
pub fn dataReader(self: Inode, alloc: std.mem.Allocator, archive: *Archive) !DataReader {
    return switch (self.hdr.inode_type) {
        .file => readerFromData(alloc, archive, self.data.file),
        .ext_file => readerFromData(alloc, archive, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn readerFromData(alloc: std.mem.Allocator, archive: *Archive, data: anytype) !DataReader {
    var out: DataReader = .init(alloc, archive.*, data.block_sizes, data.block_start, data.size);
    if (data.frag_idx != 0xFFFFFFFF)
        out.addFragment(try archive.frag_table.get(data.frag_idx), data.frag_block_offset);
    return out;
}
/// Get a threaded data reader for a file inode.
pub fn threadedDataReader(self: Inode, alloc: std.mem.Allocator, archive: *Archive) !ThreadedDataReader {
    return switch (self.hdr.inode_type) {
        .file => threadedReaderFromData(alloc, archive, self.data.file),
        .ext_file => threadedReaderFromData(alloc, archive, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn threadedReaderFromData(alloc: std.mem.Allocator, archive: *Archive, data: anytype) !ThreadedDataReader {
    var out: ThreadedDataReader = .init(alloc, archive.*, data.block_sizes, data.block_start, data.size);
    if (data.frag_idx != 0xFFFFFFFF)
        out.addFragment(try archive.frag_table.get(data.frag_idx), data.frag_block_offset);
    return out;
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

/// Returns the xattr index for the given inode. If the inode isn't an extended variant or doesn't have any, the u32 max is returned (0xFFFFFFFF).
pub fn xattrIdx(self: Inode) u32 {
    return switch (self.data) {
        .ext_dir => |d| d.xattr_id,
        .ext_file => |f| f.xattr_idx,
        .ext_symlink => |s| s.xattr_idx,
        .ext_block_dev, .ext_char_dev => |d| d.xattr_idx,
        .ext_fifo, .ext_socket => |i| i.xattr_idx,
        else => 0xFFFFFFFF,
    };
}

/// Applies the Inode's metadata to the given File.
/// Mod time is always set, but permissions and xattrs are set based on the given ExtractionOptions.
pub fn setMetadata(self: Inode, alloc: std.mem.Allocator, archive: *Archive, fil: std.fs.File, options: ExtractionOptions) !void {
    const time = @as(i128, self.hdr.mod_time) * 1000000000;
    try fil.updateTimes(time, time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try archive.id_table.get(self.hdr.uid_idx), try archive.id_table.get(self.hdr.gid_idx));
    }
    if (!options.ignore_xattr) {
        const idx = self.xattrIdx();
        if (idx == 0xFFFFFFFF) return;
        const xattrs = try archive.xattr_table.get(alloc, idx);
        defer alloc.free(xattrs);
        for (xattrs) |kv| {
            defer {
                alloc.free(kv.key);
                alloc.free(kv.value);
            }
            const res = std.os.linux.fsetxattr(fil.handle, @ptrCast(kv.key), @ptrCast(kv.value), kv.value.len, 0);
            if (res != 0) {
                if (options.verbose)
                    options.verbose_writer.?.print("fsetxattr has result of: {}\n", .{res}) catch {};
                return error.SetXattr;
            }
        }
    }
}

/// Extract the inode to the given path.
pub fn extractTo(self: Inode, alloc: std.mem.Allocator, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    if (options.threads > 1) return self.extractToThreaded(alloc, archive, path, options);
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            // Removing any trailing separators since that's the easiest path forward.
            if (path[path.len - 1] == '/') return self.extractTo(alloc, archive, path[0 .. path.len - 1], options);
            std.fs.cwd().makeDir(path) catch |err| {
                if (err != std.fs.Dir.MakeError.PathAlreadyExists) return err;
            };
            const entries = try self.dirEntries(alloc, archive.*);
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

            var fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            try self.setMetadata(alloc, archive, fil, options);
        },
        .file, .ext_file => try self.extractRegFile(alloc, archive, path, options),
        .symlink, .ext_symlink => try self.extractSymlink(path),
        else => try self.extractDevice(alloc, archive, path, options),
    }
}

/// Extract the inode to the given path. Multi-threaded.
/// Functions identically to extractTo on all but regular files and directories.
fn extractToThreaded(self: Inode, allocator: std.mem.Allocator, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            // Removing any trailing separators since that's the easiest path forward.
            if (path[path.len - 1] == '/') return self.extractToThreaded(allocator, archive, path[0 .. path.len - 1], options);

            // Arena Allocator
            var stack_alloc = std.heap.stackFallback(1024 * 1024, allocator);
            var arena_alloc: std.heap.ArenaAllocator = .init(stack_alloc.get());
            defer arena_alloc.deinit();
            var thread_alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = arena_alloc.allocator() };
            const alloc = thread_alloc.allocator();

            var wg: WaitGroup = .{};
            // defer if(!options.ignore_permissions) perms.?.deinit(alloc); We don't need to do this due to ArenaAllocator
            var pool: Pool = undefined;
            try pool.init(.{ .allocator = alloc, .n_jobs = options.threads - 1 });
            defer pool.deinit();
            var out_err: ?anyerror = null;

            wg.start();
            self.extractThread(alloc, archive, path, options, .{ .wg = &wg }, &pool, &out_err);
            pool.waitAndWork(&wg);
            if (out_err != null) return out_err.?;

            var fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            try self.setMetadata(alloc, archive, fil, options);
        },
        .file, .ext_file => {
            var pool: Pool = undefined;
            try pool.init(.{ .allocator = allocator, .n_jobs = options.threads - 1 });
            defer pool.deinit();

            // Arena Allocator
            var stack_alloc = std.heap.stackFallback(1024 * 1024, allocator);
            var arena_alloc: std.heap.ArenaAllocator = .init(stack_alloc.get());
            defer arena_alloc.deinit();
            var thread_alloc: std.heap.ThreadSafeAllocator = .{ .child_allocator = arena_alloc.allocator() };
            const alloc = thread_alloc.allocator();

            var wg: WaitGroup = .{};
            var out_err: ?anyerror = null;

            self.extractThread(alloc, archive, path, options, .{ .wg = &wg }, &pool, &out_err);
            pool.waitAndWork(&wg);

            if (out_err != null) return out_err.?;

            var fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            try self.setMetadata(alloc, archive, fil, options);
        },
        .symlink, .ext_symlink => try self.extractSymlink(path),
        else => try self.extractDevice(allocator, archive, path, options),
    }
}

fn extractThreadEntry(
    entry: DirEntry,
    alloc: std.mem.Allocator,
    archive: *Archive,
    path: []const u8,
    options: ExtractionOptions,
    finish: FinishUnion,
    pool: *Pool,
    out_err: *?anyerror,
) void {
    var new_path = alloc.alloc(u8, path.len + entry.name.len + 1) catch |err| {
        finish.finish();
        out_err.* = err;
        return;
    };
    @memcpy(new_path[0..path.len], path);
    @memcpy(new_path[path.len + 1 ..], entry.name);
    new_path[path.len] = '/';
    var inode = readFromEntry(alloc, archive, entry) catch |err| {
        out_err.* = err;
        finish.finish();
        return;
    };
    inode.extractThread(alloc, archive, new_path, options, finish, pool, out_err);
}

/// Extract threadedly the inode to the path.
fn extractThread(
    self: Inode,
    alloc: std.mem.Allocator,
    archive: *Archive,
    path: []const u8,
    options: ExtractionOptions,
    finish: FinishUnion,
    pool: *Pool,
    out_err: *?anyerror,
) void {
    if (options.verbose)
        options.verbose_writer.?.print("Extracting inode #{} to {s}\n", .{ self.hdr.num, path }) catch {};
    defer finish.finish();
    if (out_err.* != null) return;
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            _ = std.fs.cwd().makePathStatus(path) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error creating {s}: {}\n", .{ path, err }) catch {};
                out_err.* = err;
                return;
            };

            const entries = self.dirEntries(alloc, archive.*) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error getting directory entries for inode #{} (extracting to {s}): {}\n", .{ self.hdr.num, path, err }) catch {};
                out_err.* = err;
                return;
            };
            const fin = InodeFinish.create(
                alloc,
                self,
                path,
                archive,
                options,
                finish,
                out_err,
                null,
                entries.len,
            ) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error allocating memory\n", .{}) catch {};
                out_err.* = err;
                return;
            };
            // defer files.deinit(alloc); We don't need to do this due to ArenaAllocator
            for (entries) |entry| {
                if (entry.inode_type == .dir) {
                    extractThreadEntry(
                        entry,
                        alloc,
                        archive,
                        path,
                        options,
                        .{ .fin = fin },
                        pool,
                        out_err,
                    );
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
                        FinishUnion{ .fin = fin },
                        pool,
                        out_err,
                    },
                ) catch |err| {
                    fin.finish();
                    if (options.verbose)
                        options.verbose_writer.?.print("Error starting extraction thread: {}\n", .{err}) catch {};
                    out_err.* = err;
                    continue;
                };
            }
        },
        .file, .ext_file => {
            const fil = std.fs.cwd().createFile(path, .{}) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error creating {s}: {}\n", .{ path, err }) catch {};
                out_err.* = err;
                return;
            };
            var data = self.threadedDataReader(alloc, archive) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print(
                        "Error creating data reader for inode #{} (extracting to {s}): {}\n",
                        .{ self.hdr.num, path, err },
                    ) catch {};
                out_err.* = err;
                return;
            };
            const fin = InodeFinish.create(
                alloc,
                self,
                path,
                archive,
                options,
                finish,
                out_err,
                fil,
                data.num_blocks,
            ) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error allocating memory\n", .{}) catch {};
                out_err.* = err;
                return;
            };
            data.extractThreaded(fil, pool, fin) catch |err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Error spawning threads: {}\n", .{err}) catch {};
                out_err.* = err;
                return;
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
fn extractRegFile(self: Inode, alloc: std.mem.Allocator, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
    var fil = try std.fs.cwd().createFile(path, .{ .exclusive = true });
    defer fil.close();
    var wrt = fil.writer(&[0]u8{});
    var dat_rdr = try self.dataReader(alloc, archive);
    defer dat_rdr.deinit();
    _ = try dat_rdr.interface.streamRemaining(&wrt.interface);
    try wrt.interface.flush();

    try self.setMetadata(alloc, archive, fil, options);
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
fn extractDevice(self: Inode, alloc: std.mem.Allocator, archive: *Archive, path: []const u8, options: ExtractionOptions) !void {
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
    try self.setMetadata(alloc, archive, fil, options);
}

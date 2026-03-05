const std = @import("std");
const Allocator = std.mem.Allocator;
const Pool = std.Thread.Pool;
const WaitGroup = std.Thread.WaitGroup;

const Archive = @import("../archive.zig");
const DirEntry = @import("../dir_entry.zig");
const Inode = @import("../inode.zig");
const ExtractionOptions = @import("../options.zig");
const Tables = @import("../tables.zig");
const InodeFinish = @import("inode_finish.zig");
const FinishUnion = InodeFinish.FinishUnion;
const ThreadedDataReader = @import("data_threaded.zig");

// 1 MB
const STACK_ALLOC_SIZE = 1024 * 1024;

pub fn extractTo(
    allocator: Allocator,
    inode: Inode,
    archive: Archive,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    if (path[path.len - 1] == '/')
        return extractTo(allocator, inode, archive, path[0 .. path.len - 2], options);

    var stack_alloc = std.heap.stackFallback(STACK_ALLOC_SIZE, allocator);
    var arena: std.heap.ArenaAllocator = .init(stack_alloc.get());
    defer arena.deinit();
    if (options.threads <= 1) {
        const alloc = arena.allocator();
        var tables: Tables = try .init(alloc, archive);
        return extractSingleThread(arena.allocator(), inode, archive, &tables, path, options);
    }

    var thread_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
    const alloc = thread_alloc.allocator();
    var tables: Tables = try .init(alloc, archive);

    var pool_alloc = std.heap.stackFallback(10 * 1024, alloc);
    var pool: Pool = undefined;
    try pool.init(.{ .allocator = pool_alloc.get(), .n_jobs = options.threads - 1 });

    var wg: WaitGroup = .{};
    var err: ?anyerror = null;
    wg.start();
    try pool.spawn(extractMultiThread, .{
        alloc,
        inode,
        archive,
        &tables,
        path,
        options,
        &pool,
        FinishUnion{ .wg = &wg },
        &err,
    });
    pool.waitAndWork(&wg);
    if (err != null) return err.?;
}

fn extractSingleThread(
    alloc: Allocator,
    inode: Inode,
    archive: Archive,
    tables: *Tables,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    switch (inode.hdr.inode_type) {
        .dir, .ext_dir => {
            _ = std.fs.cwd().makeDir(path) catch |err| switch (err) {
                std.fs.Dir.MakeError.PathAlreadyExists => {},
                else => return err,
            };

            // Currently we are ignoring any deinit or free calls since we know we are under an ArenaAllocator.
            // Possibly in the future, do some simple math to see if it would be safe to ONLY deinit via Arena,
            // otherwise be more conscientious about freeing memory.
            // For now, this is good enough.

            const entries = try inode.dirEntries(alloc, archive);
            for (entries) |ent| {
                const sub_inode: Inode = try .readFromEntry(alloc, archive, ent);
                const new_path = try std.mem.concat(alloc, u8, &[_][]const u8{ path, "/", ent.name });
                try extractSingleThread(alloc, sub_inode, archive, tables, new_path, options);
            }

            const fil = try std.fs.cwd().openFile(path, .{});
            defer fil.close();
            try inode.setMetadata(alloc, tables, fil, options);
        },
        .file, .ext_file => {
            var fil = try std.fs.cwd().createFile(path, .{ .exclusive = true });
            defer fil.close();
            var wrt = fil.writer(&[0]u8{});
            var dat_rdr = try inode.dataReader(alloc, archive, tables);
            defer dat_rdr.deinit();
            _ = try dat_rdr.interface.streamRemaining(&wrt.interface);
            try wrt.interface.flush();

            try inode.setMetadata(alloc, tables, fil, options);
        },
        .symlink, .ext_symlink => return extractSymlink(inode, path),
        else => return extractDeviceAndIPC(inode, alloc, tables, path, options),
    }
}

fn extractMultiThread(
    alloc: Allocator,
    inode: Inode,
    archive: Archive,
    tables: *Tables,
    path: []const u8,
    options: ExtractionOptions,
    pool: *Pool,
    fin: FinishUnion,
    err: *?anyerror,
) void {
    if (err.* != null) {
        fin.finish();
        return;
    }
    switch (inode.hdr.inode_type) {
        .dir, .ext_dir => {
            _ = std.fs.cwd().makeDir(path) catch |res_err| switch (res_err) {
                std.fs.Dir.MakeError.PathAlreadyExists => {},
                else => {
                    err.* = res_err;
                    fin.finish();
                    return;
                },
            };

            // Currently we are ignoring any deinit or free calls since we know we are under an ArenaAllocator.
            // Possibly in the future, do some simple math to see if it would be safe to ONLY deinit via Arena,
            // otherwise be more conscientious about freeing memory.
            // For now, this is good enough.

            const entries = inode.dirEntries(alloc, archive) catch |res_err| {
                err.* = res_err;
                fin.finish();
                return;
            };

            if (entries.len == 0) {
                fin.finish();
                return;
            }

            var dir_fin = InodeFinish.create(
                alloc,
                inode,
                path,
                tables,
                options,
                fin,
                err,
                null,
                entries.len,
            ) catch |res_err| {
                err.* = res_err;
                fin.finish();
                return;
            };

            for (entries) |ent| {
                if (ent.inode_type == .dir) {
                    extractEntry(
                        alloc,
                        ent,
                        archive,
                        tables,
                        path,
                        options,
                        pool,
                        .{ .fin = dir_fin },
                        err,
                    );
                    continue;
                }

                pool.spawn(
                    extractEntry,
                    .{ alloc, ent, archive, tables, path, options, pool, FinishUnion{ .fin = dir_fin }, err },
                ) catch |res_err| {
                    err.* = res_err;
                    dir_fin.finish();
                    return;
                };
            }
        },
        .file, .ext_file => {
            const fil = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |res_err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Can't create file at {s}: {}\n", .{ path, res_err }) catch {};
                err.* = res_err;
                fin.finish();
                return;
            };

            var data_rdr = threadedDataReader(inode, alloc, archive, tables) catch |res_err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Can't create data reader for inode #{} (extracting to {s}): {}\n", .{ inode.hdr.num, path, res_err }) catch {};
                err.* = res_err;
                fin.finish();
                return;
            };
            if (data_rdr == null) {
                inode.setMetadata(alloc, tables, fil, options) catch |res_err| {
                    if (options.verbose)
                        options.verbose_writer.?.print("Can't set metadata to {s}: {}\n", .{ path, res_err }) catch {};
                    err.* = res_err;
                };
                fin.finish();
                return;
            }
            const file_fin = InodeFinish.create(
                alloc,
                inode,
                path,
                tables,
                options,
                fin,
                err,
                fil,
                data_rdr.?.num_blocks,
            ) catch |res_err| {
                if (options.verbose)
                    options.verbose_writer.?.print("Can't create callback for inode #{} (extracting to {s}): {}\n", .{ inode.hdr.num, path, res_err }) catch {};
                err.* = res_err;
                fin.finish();
                return;
            };

            data_rdr.?.extractThreaded(fil, pool, file_fin);
        },
        .symlink, .ext_symlink => {
            extractSymlink(inode, path) catch |res_err| {
                err.* = res_err;
            };
            fin.finish();
        },
        else => {
            extractDeviceAndIPC(inode, alloc, tables, path, options) catch |res_err| {
                err.* = res_err;
            };
            fin.finish();
        },
    }
}

fn extractEntry(
    alloc: Allocator,
    ent: DirEntry,
    archive: Archive,
    tables: *Tables,
    path: []const u8,
    options: ExtractionOptions,
    pool: *Pool,
    fin: FinishUnion,
    err: *?anyerror,
) void {
    const new_path = std.mem.concat(alloc, u8, &[_][]const u8{ path, "/", ent.name }) catch |res_err| {
        err.* = res_err;
        fin.finish();
        return;
    };

    const inode = Inode.readFromEntry(alloc, archive, ent) catch |res_err| {
        err.* = res_err;
        fin.finish();
        return;
    };
    extractMultiThread(alloc, inode, archive, tables, new_path, options, pool, fin, err);
}

/// Get a threaded data reader for a file inode.
fn threadedDataReader(self: Inode, alloc: std.mem.Allocator, archive: Archive, tables: *Tables) !?ThreadedDataReader {
    return switch (self.hdr.inode_type) {
        .file => threadedReaderFromData(alloc, archive, tables, self.data.file),
        .ext_file => threadedReaderFromData(alloc, archive, tables, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn threadedReaderFromData(alloc: std.mem.Allocator, archive: Archive, tables: *Tables, data: anytype) !?ThreadedDataReader {
    if (data.block_sizes.len == 0 and data.frag_idx == 0xFFFFFFFF) return null;
    var out: ThreadedDataReader = .init(alloc, archive, data.block_sizes, data.block_start, data.size);
    if (data.frag_idx != 0xFFFFFFFF)
        out.addFragment(try tables.frag_table.get(data.frag_idx), data.frag_block_offset);
    return out;
}

/// Creates the symlink described by the inode.
/// Sets metadata.
fn extractSymlink(self: Inode, path: []const u8) !void {
    const target = switch (self.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };
    try std.fs.cwd().symLink(target, path, .{});
}
/// Creates the device described by the inode.
/// Sets metadata.
fn extractDeviceAndIPC(self: Inode, alloc: std.mem.Allocator, tables: *Tables, path: []const u8, options: ExtractionOptions) !void {
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
    try self.setMetadata(alloc, tables, fil, options);
}

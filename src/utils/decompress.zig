const std = @import("std");
const Io = std.Io;

const Super = @import("../archive.zig").Super;
const Decomp = @import("../decomp.zig");
const Directory = @import("../dir.zig");
const FragCache = @import("../frag_cache.zig");
const Inode = @import("../inode.zig");
const Lookup = @import("../lookup.zig");
const Options = @import("../options.zig");
const DataReader = @import("data_reader.zig");
const DataExtractor = @import("data_extractor.zig");
const MetadataReader = @import("meta.zig");

// TODO: Add verbose logging.

pub fn single(alloc: std.mem.Allocator, io: Io, data: []u8, super: Super, inode: Inode, filepath: []const u8, options: Options) !void {
    const path = std.mem.trim(u8, filepath, "/");

    var id_table: Lookup.Table(u16) = try .init(data, super.decomp_fn, super.id_table_start, super.id_count);
    defer id_table.deinit(alloc);
    var xattr_table: Lookup.Xattr = try .init(data, super.decomp_fn, super.xattr_table_start);
    defer xattr_table.deinit(alloc);
    var frag_cache: FragCache = try .init(data, super.decomp_fn, super.block_size, super.frag_table_start, super.frag_count);
    defer frag_cache.deinit(alloc);

    var pool: std.ArrayList(InodeAndPath) = try .initCapacity(alloc, 15);
    pool.appendAssumeCapacity(.{
        .inode = inode,
        .path = path,
        .root = true,
    });
    defer {
        while (pool.pop()) |in|
            if (in.path.len != path.len) in.deinit(alloc);
        pool.deinit(alloc);
    }

    var dirs: std.ArrayList(InodeAndPath) = .empty;
    defer {
        while (dirs.pop()) |dir|
            if (dir.path.len != path.len) alloc.free(dir.path);
        dirs.deinit(alloc);
    }

    var cwd = Io.Dir.cwd();

    while (pool.pop()) |in| {
        switch (in.inode.data) {
            .dir => |d| {
                try cwd.createDirPath(io, in.path);

                if (d.size <= 3) {
                    defer if (!in.root)
                        in.deinit(alloc);

                    var fil = try cwd.openFile(io, in.path, .{});
                    defer fil.close(io);

                    try applyPermissions(alloc, io, &id_table, &xattr_table, in.inode.header, d.xattr_idx, fil, options);
                    continue;
                }

                var meta: MetadataReader = .init(alloc, data[d.start + super.dir_table_start ..], super.decomp_fn);
                try meta.interface.discardAll(d.offset);

                var dir: Directory = try .read(alloc, &meta.interface, d.size);
                defer dir.deinit(alloc);

                for (dir.entries) |entry| {
                    const new_inode: Inode = try .readLocation(alloc, data, entry.start, entry.offset, super);

                    const new_path = std.mem.concat(alloc, u8, &.{ in.path, "/", entry.name }) catch |err| {
                        new_inode.deinit(alloc);
                        return err;
                    };

                    try pool.append(alloc, .{
                        .inode = new_inode,
                        .path = new_path,
                        .root = false,
                    });
                }

                try dirs.append(alloc, in);
            },
            .file => |f| {
                defer if (!in.root)
                    in.deinit(alloc);

                var atomic = try cwd.createFileAtomic(io, in.path, .{});
                defer atomic.deinit(io);

                var ext: DataExtractor = try .init(alloc, data[f.start..], super.decomp_fn, super.block_size, f.size, f.blocks);

                if (f.frag_idx != 0xFFFFFFFF) {
                    const frag = try frag_cache.get(alloc, io, f.frag_idx);
                    ext.addFrag(frag[f.frag_offset..][0 .. f.size % super.block_size]);
                }

                try ext.extract(alloc, io, atomic.file);

                try applyPermissions(alloc, io, &id_table, &xattr_table, in.inode.header, f.xattr_idx, atomic.file, options);

                try atomic.link(io);
            },
            .symlink => |s| {
                defer if (!in.root)
                    in.deinit(alloc);

                try cwd.symLink(io, s.target, in.path, .{});
            },
            .dev => |d| {
                defer if (!in.root)
                    in.deinit(alloc);

                const mode: u32 = switch (in.inode.header.type) {
                    .char_dev, .ext_char_dev => std.os.linux.DT.CHR,
                    .block_dev, .ext_block_dev => std.os.linux.DT.BLK,
                    else => unreachable,
                };

                const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

                const res = std.os.linux.mknod(sent_path, mode, d.device);
                alloc.free(sent_path);
                if (res != 0)
                    return error.MkNodError;

                var fil = try cwd.openFile(io, in.path, .{});
                defer fil.close(io);

                try applyPermissions(alloc, io, &id_table, &xattr_table, in.inode.header, d.xattr_idx, fil, options);
            },
            .fifo => |f| {
                defer if (!in.root)
                    in.deinit(alloc);

                const mode: u32 = switch (in.inode.header.type) {
                    .fifo, .ext_fifo => std.os.linux.DT.FIFO,
                    .socket, .ext_socket => std.os.linux.DT.SOCK,
                    else => unreachable,
                };

                const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

                const res = std.os.linux.mknod(sent_path, mode, 0);
                alloc.free(sent_path);
                if (res != 0)
                    return error.MkNodError;

                var fil = try cwd.openFile(io, in.path, .{});
                defer fil.close(io);

                try applyPermissions(alloc, io, &id_table, &xattr_table, in.inode.header, f.xattr_idx, fil, options);
            },
        }
    }

    while (dirs.pop()) |dir| {
        defer if (dir.path.len != path.len)
            alloc.free(dir.path);

        var fil = try cwd.openFile(io, dir.path, .{});
        defer fil.close(io);

        try applyPermissions(alloc, io, &id_table, &xattr_table, dir.inode.header, dir.inode.data.dir.xattr_idx, fil, options);
    }
}
pub fn multi(alloc: std.mem.Allocator, io: Io, data: []u8, super: Super, inode: Inode, filepath: []const u8, options: Options) !void {
    const path = std.mem.trim(u8, filepath, "/");

    var id_table: Lookup.Table(u16) = try .init(data, super.decomp_fn, super.id_table_start, super.id_count);
    defer id_table.deinit(alloc);
    var xattr_table: Lookup.Xattr = try .init(data, super.decomp_fn, super.xattr_table_start);
    defer xattr_table.deinit(alloc);
    var frag_cache: FragCache = try .init(data, super.decomp_fn, super.block_size, super.frag_table_start, super.frag_count);
    defer frag_cache.deinit(alloc);

    var group: Io.Group = .init;
    defer group.cancel(io);

    var dirs: std.ArrayList(InodeAndPath) = .empty;
    defer {
        while (dirs.pop()) |dir|
            if (dir.path.len != path.len) alloc.free(dir.path);
        dirs.deinit(alloc);
    }
    var dir_mut: Io.Mutex = .init;

    var cwd = Io.Dir.cwd();
    var err: ?anyerror = null;

    group.async(io, groupFn, .{
        alloc,
        io,
        &group,
        data,
        super,
        cwd,
        &frag_cache,
        &id_table,
        &xattr_table,
        .{ .inode = inode, .path = path, .root = true },
        options,
        &dirs,
        &dir_mut,
        &err,
    });

    try group.await(io);

    while (dirs.pop()) |dir| {
        defer if (dir.path.len != path.len)
            alloc.free(dir.path);

        var fil = try cwd.openFile(io, dir.path, .{});
        defer fil.close(io);

        try applyPermissions(alloc, io, &id_table, &xattr_table, dir.inode.header, dir.inode.data.dir.xattr_idx, fil, options);
    }
}

fn groupFn(
    alloc: std.mem.Allocator,
    io: Io,
    group: *Io.Group,
    data: []u8,
    super: Super,
    cwd: Io.Dir,
    frag_cache: *FragCache,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    in: InodeAndPath,
    options: Options,
    dirs: *std.ArrayList(InodeAndPath),
    dir_mut: *Io.Mutex,
    res_err: *?anyerror,
) Io.Cancelable!void {
    if (res_err.* != null) return;
    workThread(alloc, io, group, data, super, cwd, frag_cache, id_table, xattr_table, in, options, dirs, dir_mut, res_err) catch |err| {
        res_err.* = err;
    };
}

fn workThread(
    alloc: std.mem.Allocator,
    io: Io,
    group: *Io.Group,
    data: []u8,
    super: Super,
    cwd: Io.Dir,
    frag_cache: *FragCache,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    in: InodeAndPath,
    options: Options,
    dirs: *std.ArrayList(InodeAndPath),
    dir_mut: *Io.Mutex,
    res_err: *?anyerror,
) !void {
    switch (in.inode.data) {
        .dir => |d| {
            try cwd.createDirPath(io, in.path);

            if (d.size <= 3) {
                defer if (!in.root)
                    in.deinit(alloc);

                var fil = try cwd.openFile(io, in.path, .{});
                defer fil.close(io);

                try applyPermissions(alloc, io, id_table, xattr_table, in.inode.header, d.xattr_idx, fil, options);
                return;
            }

            var meta: MetadataReader = .init(alloc, data[d.start + super.dir_table_start ..], super.decomp_fn);
            try meta.interface.discardAll(d.offset);

            var dir: Directory = try .read(alloc, &meta.interface, d.size);
            defer dir.deinit(alloc);

            for (dir.entries) |entry| {
                const new_inode: Inode = try .readLocation(alloc, data, entry.start, entry.offset, super);

                const new_path = std.mem.concat(alloc, u8, &.{ in.path, "/", entry.name }) catch |err| {
                    new_inode.deinit(alloc);
                    return err;
                };

                group.async(io, groupFn, .{
                    alloc,
                    io,
                    group,
                    data,
                    super,
                    cwd,
                    frag_cache,
                    id_table,
                    xattr_table,
                    .{ .inode = new_inode, .path = new_path, .root = false },
                    options,
                    dirs,
                    dir_mut,
                    res_err,
                });
            }

            try dir_mut.lock(io);
            defer dir_mut.unlock(io);
            try dirs.append(alloc, in);
        },
        .file => |f| {
            defer if (!in.root)
                in.deinit(alloc);

            var atomic = try cwd.createFileAtomic(io, in.path, .{});
            defer atomic.deinit(io);

            var rdr: DataReader = try .init(alloc, data[f.start..], super.decomp_fn, super.block_size, f.size, f.blocks);
            defer rdr.deinit();

            if (f.frag_idx != 0xFFFFFFFF) {
                const frag = try frag_cache.get(alloc, io, f.frag_idx);
                rdr.addFrag(frag[f.frag_offset..][0 .. f.size % super.block_size]);
            }

            var buf: [1024 * 50]u8 = undefined; // TODO: find a resonable buffer size.
            var writer = atomic.file.writer(io, &buf);
            _ = try rdr.interface.streamRemaining(&writer.interface);
            try writer.flush();

            try applyPermissions(alloc, io, id_table, xattr_table, in.inode.header, f.xattr_idx, atomic.file, options);

            try atomic.link(io);
        },
        .symlink => |s| {
            defer if (!in.root)
                in.deinit(alloc);

            try cwd.symLink(io, s.target, in.path, .{});
        },
        .dev => |d| {
            defer if (!in.root)
                in.deinit(alloc);

            const mode: u32 = switch (in.inode.header.type) {
                .char_dev, .ext_char_dev => std.os.linux.DT.CHR,
                .block_dev, .ext_block_dev => std.os.linux.DT.BLK,
                else => unreachable,
            };

            const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

            const res = std.os.linux.mknod(sent_path, mode, d.device);
            alloc.free(sent_path);
            if (res != 0)
                return error.MkNodError;

            var fil = try cwd.openFile(io, in.path, .{});
            defer fil.close(io);

            try applyPermissions(alloc, io, id_table, xattr_table, in.inode.header, d.xattr_idx, fil, options);
        },
        .fifo => |f| {
            defer if (!in.root)
                in.deinit(alloc);

            const mode: u32 = switch (in.inode.header.type) {
                .fifo, .ext_fifo => std.os.linux.DT.FIFO,
                .socket, .ext_socket => std.os.linux.DT.SOCK,
                else => unreachable,
            };

            const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

            const res = std.os.linux.mknod(sent_path, mode, 0);
            alloc.free(sent_path);
            if (res != 0)
                return error.MkNodError;

            var fil = try cwd.openFile(io, in.path, .{});
            defer fil.close(io);

            try applyPermissions(alloc, io, id_table, xattr_table, in.inode.header, f.xattr_idx, fil, options);
        },
    }
}

// Utils

const InodeAndPath = struct {
    inode: Inode,
    path: []const u8,
    root: bool,

    fn deinit(self: InodeAndPath, alloc: std.mem.Allocator) void {
        if (self.root) return;
        self.inode.deinit(alloc);
        alloc.free(self.path);
    }
};

fn applyPermissions(alloc: std.mem.Allocator, io: Io, id_table: *Lookup.Table(u16), xattr_table: *Lookup.Xattr, header: Inode.Header, xattr_idx: ?u32, fil: Io.File, options: Options) !void {
    if (!options.ignore_permissions) {
        try fil.setPermissions(io, @enumFromInt(header.permission));

        try fil.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, @intCast(header.mod_time)) * std.time.ns_per_ms) } });

        try fil.setOwner(io, try id_table.get(alloc, io, header.uid_idx), try id_table.get(alloc, io, header.gid_idx));
    }
    if (!options.ignore_xattr and xattr_idx != null) {
        const xattrs = try xattr_table.get(alloc, io, xattr_idx.?);
        defer {
            for (xattrs) |kv|
                kv.deinit(alloc);
            alloc.free(xattrs);
        }

        for (xattrs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.name, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return error.FSetXattrError;
        }
    }
}

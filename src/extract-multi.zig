const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;

const DataExtractor = @import("data/extractor.zig");
const DataReader = @import("data/reader.zig");
const Decomp = @import("decomp.zig");
const Directory = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const Lookup = @import("lookup.zig");
const MetadataReader = @import("meta_rdr.zig");
const Superblock = @import("archive.zig").Superblock;
const Cache = @import("util/cache.zig");
const XattrTable = @import("xattr.zig");

pub fn extract(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    inode: Inode,
    ext_loc: []const u8,
    options: ExtractionOptions,
) !void {
    const path = std.mem.trim(u8, ext_loc, "/");

    var id_table: Lookup.Table(u16) = .init(alloc, data, decomp, super.id_start, super.id_count);
    defer id_table.deinit();

    var xattr_table: XattrTable = .init(alloc, data, decomp, super.xattr_start);
    defer xattr_table.deinit();

    var cache: Cache = .init(alloc, data, decomp);
    defer cache.deinit();

    var frag_table: Lookup.Table(Lookup.FragEntry) = .init(alloc, data, decomp, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    var dirs: std.PriorityDequeue(DirReturn, Io.Mutex, compareDir) = .initContext(.init);
    defer dirs.deinit(alloc);

    errdefer while (dirs.popMax()) |d| {
        if (d.hdr.num != inode.hdr.num)
            alloc.free(d.path);
    };

    var atomic_err: ?Error = null;

    var group: Io.Group = .init;

    switch (inode.hdr.type) {
        .dir, .ext_dir => group.async(io, extractDir, .{
            alloc,
            io,
            super,
            data,
            decomp,
            &cache,
            &frag_table,
            &id_table,
            &xattr_table,
            &group,
            &dirs,
            inode,
            path,
            options,
            true,
            &atomic_err,
        }),
        .file, .ext_file => group.async(io, extractFile, .{
            alloc, io, super.block_size, data, decomp, &cache, &frag_table, &id_table, &xattr_table, inode, path, options, true, &atomic_err,
        }),
        .symlink, .ext_symlink => group.async(io, extractSymlink, .{
            alloc,
            io,
            inode,
            path,
            true,
            &atomic_err,
        }),
        else => group.async(io, extractNode, .{
            alloc,
            io,
            &id_table,
            &xattr_table,
            inode,
            path,
            options,
            true,
            &atomic_err,
        }),
    }

    try group.await(io);

    while (dirs.popMax()) |d| {
        defer if (d.hdr.num != inode.hdr.num)
            alloc.free(d.path);
        try setMetadata(alloc, io, &id_table, &xattr_table, d.hdr, path, options, d.xattr_idx);
    }
}

fn extractDir(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    group: *Io.Group,
    dirs: *std.PriorityDequeue(DirReturn, Io.Mutex, compareDir),
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
    origin: bool,
    atomic_err: *?Error,
) error{Canceled}!void {
    errdefer if (!origin) alloc.free(path);

    var xattr_idx: u32 = 0xFFFFFFFF;

    Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };

    _ = blk: {
        var dir: Directory = switch (inode.data) {
            .dir => |d| d_blk: {
                var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
                meta.interface.discardAll(d.block_offset) catch |err| break :blk err;

                break :d_blk Directory.init(alloc, &meta.interface, d.size) catch |err| break :blk err;
            },
            .ext_dir => |d| d_blk: {
                xattr_idx = d.xattr_idx;

                var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
                meta.interface.discardAll(d.block_offset) catch |err| break :blk err;

                break :d_blk Directory.init(alloc, &meta.interface, d.size) catch |err| break :blk err;
            },
            else => unreachable,
        };
        defer dir.deinit(alloc);

        for (dir.entries) |entry| {
            var new_inode: Inode = Inode.initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry) catch |err|
                break :blk err;

            const new_path = std.mem.concat(alloc, u8, &.{ path, "/", entry.name }) catch |err| {
                new_inode.deinit(alloc);
                break :blk err;
            };

            switch (entry.type) {
                .dir => group.async(io, extractDir, .{
                    alloc,
                    io,
                    super,
                    data,
                    decomp,
                    cache,
                    frag_table,
                    id_table,
                    xattr_table,
                    group,
                    dirs,
                    new_inode,
                    new_path,
                    options,
                    false,
                    atomic_err,
                }),
                .file => group.async(io, extractFile, .{
                    alloc,
                    io,
                    super.block_size,
                    data,
                    decomp,
                    cache,
                    frag_table,
                    id_table,
                    xattr_table,
                    new_inode,
                    new_path,
                    options,
                    false,
                    atomic_err,
                }),
                .symlink => group.async(io, extractSymlink, .{
                    alloc,
                    io,
                    new_inode,
                    new_path,
                    false,
                    atomic_err,
                }),
                else => group.async(io, extractNode, .{
                    alloc,
                    io,
                    id_table,
                    xattr_table,
                    new_inode,
                    new_path,
                    options,
                    false,
                    atomic_err,
                }),
            }
        }
    } catch |err| {
        atomic_err.* = err;
        return;
    };

    try dirs.context.lock(io);
    defer dirs.context.unlock(io);

    dirs.push(alloc, .{ .hdr = inode.hdr, .path = path, .xattr_idx = xattr_idx }) catch |err| {
        atomic_err.* = err;
    };
}
fn extractFile(
    alloc: std.mem.Allocator,
    io: Io,
    block_size: u32,
    data: []u8,
    decomp: Decomp.Fn,
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
    origin: bool,
    atomic_err: *?Error,
) error{Canceled}!void {
    defer if (!origin) {
        inode.deinit(alloc);
        alloc.free(path);
    };

    var atomic = Io.Dir.cwd().createFileAtomic(io, path, .{}) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };
    defer atomic.deinit(io);

    var xattr_idx: u32 = 0xFFFFFFFF;

    var extractor: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var ext: DataExtractor = .init(data, decomp, block_size, f.blocks, f.block_start, f.size);
            ext.addCache(cache);

            if (f.frag_idx != 0xFFFFFFFF) {
                const entry: Lookup.FragEntry = frag_table.get(io, f.frag_idx) catch |err| break :blk err;

                if (entry.size.uncompressed) {
                    ext.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
                } else {
                    const frag_blk = cache.get(io, entry.block_start, entry.size.size) catch |err| break :blk err;
                    ext.addFrag(frag_blk, f.frag_offset);
                }
            }
            break :blk ext;
        },
        .ext_file => |f| blk: {
            xattr_idx = f.xattr_idx;

            var ext: DataExtractor = .init(data, decomp, block_size, f.blocks, f.block_start, f.size);
            ext.addCache(cache);

            if (f.frag_idx != 0xFFFFFFFF) {
                const entry: Lookup.FragEntry = frag_table.get(io, f.frag_idx) catch |err| break :blk err;

                if (entry.size.uncompressed) {
                    ext.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
                } else {
                    const frag_blk = cache.get(io, entry.block_start, entry.size.size) catch |err| break :blk err;
                    ext.addFrag(frag_blk, f.frag_offset);
                }
            }
            break :blk ext;
        },
        else => unreachable,
    } catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };

    extractor.extractAsync(alloc, io, atomic.file) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };

    atomic.link(io) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };

    setMetadata(alloc, io, id_table, xattr_table, inode.hdr, path, options, xattr_idx) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };
}
fn extractSymlink(
    alloc: std.mem.Allocator,
    io: Io,
    inode: Inode,
    path: []const u8,
    origin: bool,
    atomic_err: *?Error,
) error{Canceled}!void {
    defer if (!origin) {
        inode.deinit(alloc);
        alloc.free(path);
    };

    const target = switch (inode.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };
    Io.Dir.cwd().symLink(io, path, target, .{}) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.* = e;
            return;
        },
    };
}
fn extractNode(
    alloc: std.mem.Allocator,
    io: Io,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
    origin: bool,
    atomic_err: *?Error,
) error{Canceled}!void {
    defer if (!origin) alloc.free(path);

    var xattr_idx: u32 = 0xFFFFFFFF;

    var mode: u32 = undefined;
    var dev: u32 = 0;

    const DT = std.os.linux.DT;

    switch (inode.data) {
        .block_dev => |d| {
            mode = DT.BLK;
            dev = d.device;
        },
        .ext_block_dev => |d| {
            xattr_idx = d.xattr_idx;

            mode = DT.BLK;
            dev = d.device;
        },
        .char_dev => |d| {
            mode = DT.CHR;
            dev = d.device;
        },
        .ext_char_dev => |d| {
            xattr_idx = d.xattr_idx;

            mode = DT.CHR;
            dev = d.device;
        },
        .fifo => mode = DT.FIFO,
        .ext_fifo => |f| {
            xattr_idx = f.xattr_idx;

            mode = DT.FIFO;
        },
        .socket => mode = DT.SOCK,
        .ext_socket => |s| {
            xattr_idx = s.xattr_idx;

            mode = DT.SOCK;
        },
        else => unreachable,
    }

    const sentinel_path = alloc.dupeSentinel(u8, path, 0) catch |err| {
        atomic_err.* = err;
        return;
    };

    const res = std.os.linux.mknod(sentinel_path, mode, dev);
    alloc.free(sentinel_path);
    if (res != 0) {
        atomic_err.* = Error.MknodError;
        return;
    }

    setMetadata(alloc, io, id_table, xattr_table, inode.hdr, path, options, xattr_idx) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| atomic_err.* = e,
    };
}
fn setMetadata(
    alloc: std.mem.Allocator,
    io: Io,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    hdr: Inode.Header,
    path: []const u8,
    options: ExtractionOptions,
    xattr_idx: u32,
) Error!void {
    if (options.ignore_permissions and (options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    var fil: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer fil.close(io);

    if (!options.ignore_xattr and xattr_idx != 0xFFFFFFFF) {
        const xattr = try xattr_table.get(alloc, io, xattr_idx);
        defer xattr.deinit(alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return error.SetXattrError;
        }
    }
    if (!options.ignore_permissions) {
        try fil.setTimestamps(io, .{
            .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(@as(i96, @intCast(hdr.mod_time)) * std.time.ns_per_s)),
        });
        try fil.setPermissions(io, @enumFromInt(hdr.permissions));
        try fil.setOwner(io, try id_table.get(io, hdr.uid_idx), try id_table.get(io, hdr.gid_idx));
    }
}

fn compareDir(_: Io.Mutex, a: DirReturn, b: DirReturn) std.math.Order {
    return std.math.order(std.mem.count(u8, a.path, "/"), std.mem.count(u8, b.path, "/"));
}

// Types

const Error = error{ MknodError, SetXattrError } || Decomp.Error || Directory.Error || DataExtractor.Error || Io.Dir.CreateDirPathError ||
    Io.Dir.SymLinkError || Io.File.Atomic.LinkError || Io.Reader.StreamRemainingError;

const DirReturn = struct {
    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: u32,
};

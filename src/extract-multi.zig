const std = @import("std");
const Io = std.Io;

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

    var buf: [150]ReturnUnion = undefined;
    var sel: Io.Select(ReturnUnion) = .init(io, &buf);
    defer while (sel.cancel()) |res|
        switch (res) {
            .path => |p| {
                const path_return = p catch continue;
                if (path_return.path.len != path.len)
                    alloc.free(path_return.path);
            },
            else => {},
        };

    var loop = io.async(finishLoop, .{ alloc, io, &sel, &id_table, &xattr_table, inode.hdr.num, options });

    var cache: Cache = .init(alloc, data, decomp);
    defer cache.deinit();

    var frag_table: Lookup.Table(Lookup.FragEntry) = .init(alloc, data, decomp, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    switch (inode.hdr.type) {
        .file, .ext_file => sel.async(
            .path,
            extractFile,
            .{ alloc, io, data, decomp, super.block_size, &cache, &frag_table, inode, path, true },
        ),
        .dir, .ext_dir => sel.async(
            .path,
            extractDir,
            .{ alloc, io, super, data, decomp, &sel, &cache, &frag_table, inode, path, true },
        ),
        .symlink, .ext_symlink => sel.async(
            .void,
            extractSymlink,
            .{ alloc, io, inode, path, true },
        ),
        else => sel.async(
            .path,
            extractNod,
            .{ alloc, inode, path, true },
        ),
    }

    // try loop.await(io);
    loop.await(io) catch |err| {
        std.debug.print("err: {}\n", .{err});
        return err;
    };
}

fn dirOrder(_: void, a: PathReturn, b: PathReturn) std.math.Order {
    return std.math.order(std.mem.count(u8, a.path, "/"), std.mem.count(u8, b.path, "/"));
}
fn finishLoop(alloc: std.mem.Allocator, io: Io, sel: *Io.Select(ReturnUnion), id_table: *Lookup.Table(u16), xattr_table: *XattrTable, start_num: u32, options: ExtractionOptions) !void {
    var dirs: std.PriorityDequeue(PathReturn, void, dirOrder) = .empty;
    defer dirs.deinit(alloc);
    errdefer while (dirs.popMax()) |d|
        if (d.hdr.num != start_num) alloc.free(d.path);

    while (true) {
        const value: ReturnUnion = try sel.await();

        const path_ret = switch (value) {
            .void => {
                _ = sel.group.token.load(.unordered) orelse break;
                continue;
            },
            .path => |p| try p,
        };

        if (options.ignore_permissions and (options.ignore_xattr or path_ret.xattr_idx == null)) {
            if (path_ret.hdr.num != start_num)
                alloc.free(path_ret.path);
            continue;
        }

        if (path_ret.hdr.type == .dir or path_ret.hdr.type == .ext_dir) {
            dirs.push(alloc, path_ret) catch |err| {
                if (path_ret.hdr.num != start_num)
                    alloc.free(path_ret.path);
                return err;
            };
            continue;
        }
        defer if (path_ret.hdr.num != start_num)
            alloc.free(path_ret.path);

        var file = try Io.Dir.cwd().openFile(io, path_ret.path, .{});
        defer file.close(io);

        if (!options.ignore_xattr and path_ret.xattr_idx != null) {
            const xattr = try xattr_table.get(alloc, io, path_ret.xattr_idx.?);
            defer xattr.deinit(alloc);

            for (xattr.kvs) |kv| {
                const res = std.os.linux.fsetxattr(file.handle, kv.key, kv.value.ptr, kv.value.len, 0);
                if (res != 0)
                    return error.SetXattrError;
            }
        }
        if (!options.ignore_permissions) {
            try file.setTimestamps(io, .{
                .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(@as(i96, @intCast(path_ret.hdr.mod_time)) * std.time.ns_per_s)),
            });
            try file.setPermissions(io, @enumFromInt(path_ret.hdr.permissions));
            try file.setOwner(io, try id_table.get(io, path_ret.hdr.uid_idx), try id_table.get(io, path_ret.hdr.gid_idx));
        }

        _ = sel.group.token.load(.unordered) orelse break;
    }

    while (dirs.popMax()) |path_ret| {
        defer if (path_ret.hdr.num != start_num)
            alloc.free(path_ret.path);

        var file = try Io.Dir.cwd().openFile(io, path_ret.path, .{});
        defer file.close(io);

        if (!options.ignore_xattr and path_ret.xattr_idx != null) {
            const xattr = try xattr_table.get(alloc, io, path_ret.xattr_idx.?);
            defer xattr.deinit(alloc);

            for (xattr.kvs) |kv| {
                const res = std.os.linux.fsetxattr(file.handle, kv.key, kv.value.ptr, kv.value.len, 0);
                if (res != 0)
                    return error.SetXattrError;
            }
        }
        if (!options.ignore_permissions) {
            try file.setTimestamps(io, .{
                .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(@as(i96, @intCast(path_ret.hdr.mod_time)) * std.time.ns_per_s)),
            });
            try file.setPermissions(io, @enumFromInt(path_ret.hdr.permissions));
            try file.setOwner(io, try id_table.get(io, path_ret.hdr.uid_idx), try id_table.get(io, path_ret.hdr.gid_idx));
        }
    }
}

fn extractDir(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    sel: *Io.Select(ReturnUnion),
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    inode: Inode,
    path: []const u8,
    origin: bool,
) Error!PathReturn {
    defer if (!origin) inode.deinit(alloc);
    errdefer if (!origin) alloc.free(path);

    var ret: PathReturn = .{
        .hdr = inode.hdr,
        .path = path,
    };

    try Io.Dir.cwd().createDirPath(io, path);

    var dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadataReader = .init(alloc, data, decomp, d.block_start + super.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;

            var meta: MetadataReader = .init(alloc, data, decomp, d.block_start + super.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(alloc);

    for (dir.entries) |entry| {
        var new_inode: Inode = try .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry);

        const new_path = std.mem.concat(alloc, u8, &.{ path, "/", entry.name }) catch |err| {
            new_inode.deinit(alloc);
            return err;
        };

        switch (entry.type) {
            .dir => sel.async(.path, extractDir, .{ alloc, io, super, data, decomp, sel, cache, frag_table, new_inode, new_path, false }),
            .file => sel.async(.path, extractFile, .{ alloc, io, data, decomp, super.block_size, cache, frag_table, new_inode, new_path, false }),
            .symlink => sel.async(.void, extractSymlink, .{ alloc, io, new_inode, new_path, false }),
            else => sel.async(.path, extractNod, .{ alloc, new_inode, new_path, false }),
        }
    }

    return ret;
}
fn extractFile(
    alloc: std.mem.Allocator,
    io: Io,
    data: []u8,
    decomp: Decomp.Fn,
    block_size: u32,
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    inode: Inode,
    path: []const u8,
    origin: bool,
) Error!PathReturn {
    defer if (!origin) inode.deinit(alloc);
    errdefer if (!origin) alloc.free(path);

    try io.checkCancel();

    var ret: PathReturn = .{
        .hdr = inode.hdr,
        .path = path,
    };

    // var ext: DataExtractor = switch (inode.data) {
    //     .file => |f| blk: {
    //         var rdr: DataExtractor = .init(data, decomp, block_size, f.blocks, f.size, f.block_start);
    //         rdr.addCache(cache);

    //         if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

    //         const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
    //         if (entry.size.uncompressed) {
    //             rdr.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
    //         } else {
    //             rdr.addFrag(try cache.get(io, entry.block_start, entry.size.size), f.frag_offset);
    //         }

    //         break :blk rdr;
    //     },
    //     .ext_file => |f| blk: {
    //         if (f.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = f.xattr_idx;

    //         var rdr: DataExtractor = .init(data, decomp, block_size, f.blocks, f.size, f.block_start);
    //         rdr.addCache(cache);

    //         if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

    //         const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
    //         if (entry.size.uncompressed) {
    //             rdr.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
    //         } else {
    //             rdr.addFrag(try cache.get(io, entry.block_start, entry.size.size), f.frag_offset);
    //         }

    //         break :blk rdr;
    //     },
    //     else => unreachable,
    // };

    // var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    // defer atomic.deinit(io);

    // try ext.extractAsync(alloc, io, atomic.file);

    // try atomic.link(io);

    var rdr: DataReader = switch (inode.data) {
        .file => |f| blk: {
            var rdr: DataReader = .init(alloc, data, decomp, block_size, f.blocks, f.size, f.block_start);
            rdr.addCache(io, cache);

            if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

            const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
            if (entry.size.uncompressed) {
                rdr.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
            } else {
                rdr.addFrag(try cache.get(io, entry.block_start, entry.size.size), f.frag_offset);
            }

            break :blk rdr;
        },
        .ext_file => |f| blk: {
            if (f.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = f.xattr_idx;

            var rdr: DataReader = .init(alloc, data, decomp, block_size, f.blocks, f.size, f.block_start);
            rdr.addCache(io, cache);

            if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

            const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
            if (entry.size.uncompressed) {
                rdr.addFrag(data[entry.block_start..][0..entry.size.size], f.frag_offset);
            } else {
                rdr.addFrag(try cache.get(io, entry.block_start, entry.size.size), f.frag_offset);
            }

            break :blk rdr;
        },
        else => unreachable,
    };

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    var writer = atomic.file.writer(io, &[0]u8{});
    _ = try rdr.interface.streamRemaining(&writer.interface);
    try writer.flush();

    try atomic.link(io);

    return ret;
}
fn extractSymlink(alloc: std.mem.Allocator, io: Io, inode: Inode, path: []const u8, origin: bool) Error!void {
    defer if (!origin) {
        inode.deinit(alloc);
        alloc.free(path);
    };

    const target = switch (inode.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };
    try Io.Dir.cwd().symLink(io, target, path, .{});
}
fn extractNod(alloc: std.mem.Allocator, inode: Inode, path: []const u8, origin: bool) Error!PathReturn {
    errdefer if (!origin)
        alloc.free(path);

    var ret: PathReturn = .{
        .hdr = inode.hdr,
        .path = path,
    };

    var dev: u32 = 0;
    var mode: u32 = undefined;

    const DT = std.posix.DT;

    switch (inode.data) {
        .char_dev => |d| {
            dev = d.device;
            mode = DT.CHR;
        },
        .block_dev => |d| {
            dev = d.device;
            mode = DT.BLK;
        },
        .ext_char_dev => |d| {
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;

            dev = d.device;
            mode = DT.CHR;
        },
        .ext_block_dev => |d| {
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;

            dev = d.device;
            mode = DT.BLK;
        },
        .fifo => mode = DT.FIFO,
        .socket => mode = DT.SOCK,
        .ext_fifo => |i| {
            if (i.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = i.xattr_idx;

            mode = DT.FIFO;
        },
        .ext_socket => |i| {
            if (i.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = i.xattr_idx;

            mode = DT.SOCK;
        },
        else => unreachable,
    }

    const sentinel_path = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(sentinel_path);

    const res = std.os.linux.mknod(sentinel_path, mode, dev);
    if (res != 0)
        return error.MknodError;

    return ret;
}

// Types

const ReturnUnion = union(enum) {
    path: Error!PathReturn,
    void: Error!void,
};

const Error = error{MknodError} || Decomp.Error || Directory.Error || DataExtractor.Error || Io.Dir.CreateDirPathError ||
    Io.Dir.SymLinkError || Io.File.Atomic.LinkError || Io.Reader.StreamRemainingError;

const PathReturn = struct {
    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: ?u32 = null,
};

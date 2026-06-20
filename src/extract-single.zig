const std = @import("std");
const Io = std.Io;

const DataReader = @import("data/reader.zig");
const Decomp = @import("decomp.zig");
const Directory = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const Lookup = @import("lookup.zig");
const MetadaReader = @import("meta_rdr.zig");
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

    var cache: Cache = .init(alloc, data, decomp);
    defer cache.deinit();

    var frag_table: Lookup.Table(Lookup.FragEntry) = .init(alloc, data, decomp, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    var id_table: Lookup.Table(u16) = .init(alloc, data, decomp, super.id_start, super.id_count);
    defer id_table.deinit();

    var xattr_table: XattrTable = .init(alloc, data, decomp, super.xattr_start);
    defer xattr_table.deinit();

    return switch (inode.hdr.type) {
        .file, .ext_file => try extractFile(alloc, io, super, data, decomp, &cache, &frag_table, &id_table, &xattr_table, inode, path, options),
        .dir, .ext_dir => try extractDir(alloc, io, super, data, decomp, &cache, &frag_table, &id_table, &xattr_table, inode, path, options),
        .symlink, .ext_symlink => try extractSymlink(io, inode, path),
        else => try extractNod(alloc, io, &id_table, &xattr_table, inode, path, options),
    };
}

fn setMetadata(
    alloc: std.mem.Allocator,
    io: Io,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
    xattr_idx: ?u32,
) !void {
    if (options.ignore_permissions and (options.ignore_xattr or xattr_idx == null)) return;

    var fil: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer fil.close(io);

    if (!options.ignore_xattr and xattr_idx != null) {
        const xattr = try xattr_table.get(alloc, io, xattr_idx.?);
        defer xattr.deinit(alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return error.SetXattrError;
        }
    }
    if (!options.ignore_permissions) {
        try fil.setTimestamps(io, .{
            .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(@as(i96, @intCast(inode.hdr.mod_time)) * std.time.ns_per_s)),
        });
        try fil.setPermissions(io, @enumFromInt(inode.hdr.permissions));
        try fil.setOwner(io, try id_table.get(io, inode.hdr.uid_idx), try id_table.get(io, inode.hdr.gid_idx));
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
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    var xattr_idx: ?u32 = null;

    try Io.Dir.cwd().createDirPath(io, path);

    var dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadaReader = .init(alloc, data, decomp, d.block_start + super.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            if (d.xattr_idx != 0xFFFFFFFF) xattr_idx = d.xattr_idx;

            var meta: MetadaReader = .init(alloc, data, decomp, d.block_start + super.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(alloc);

    for (dir.entries) |entry| {
        var new_inode: Inode = try .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry);
        defer new_inode.deinit(alloc);

        const new_path = try std.mem.concat(alloc, u8, &.{ path, "/", entry.name });
        defer alloc.free(new_path);

        switch (entry.type) {
            .file => try extractFile(alloc, io, super, data, decomp, cache, frag_table, id_table, xattr_table, new_inode, new_path, options),
            .dir => try extractDir(alloc, io, super, data, decomp, cache, frag_table, id_table, xattr_table, new_inode, new_path, options),
            .symlink => try extractSymlink(io, new_inode, new_path),
            else => try extractNod(alloc, io, id_table, xattr_table, new_inode, new_path, options),
        }
    }

    try setMetadata(alloc, io, id_table, xattr_table, inode, path, options, xattr_idx);
}
fn extractFile(
    alloc: std.mem.Allocator,
    io: Io,
    super: Superblock,
    data: []u8,
    decomp: Decomp.Fn,
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    var xattr_idx: ?u32 = null;

    var rdr: DataReader = switch (inode.data) {
        .file => |f| blk: {
            var rdr: DataReader = .init(alloc, data, decomp, super.block_size, f.blocks, f.size, f.block_start);
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
            if (f.xattr_idx != 0xFFFFFFFF) xattr_idx = f.xattr_idx;

            var rdr: DataReader = .init(alloc, data, decomp, super.block_size, f.blocks, f.size, f.block_start);
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
    defer rdr.deinit();

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    var writer = atomic.file.writer(io, &[0]u8{});
    _ = try rdr.interface.streamRemaining(&writer.interface);
    try writer.flush();

    try atomic.link(io);

    try setMetadata(alloc, io, id_table, xattr_table, inode, path, options, xattr_idx);
}
fn extractSymlink(io: Io, inode: Inode, path: []const u8) !void {
    return switch (inode.data) {
        .symlink => |s| Io.Dir.cwd().symLink(io, s.target, path, .{}),
        .ext_symlink => |s| Io.Dir.cwd().symLink(io, s.target, path, .{}),
        else => unreachable,
    };
}
fn extractNod(
    alloc: std.mem.Allocator,
    io: Io,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    options: ExtractionOptions,
) !void {
    var dev: u32 = 0;
    var mode: u32 = undefined;

    var xattr_idx: ?u32 = null;

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
            if (d.xattr_idx != 0xFFFFFFFF) xattr_idx = d.xattr_idx;

            dev = d.device;
            mode = DT.CHR;
        },
        .ext_block_dev => |d| {
            if (d.xattr_idx != 0xFFFFFFFF) xattr_idx = d.xattr_idx;

            dev = d.device;
            mode = DT.BLK;
        },
        .fifo => mode = DT.FIFO,
        .socket => mode = DT.SOCK,
        .ext_fifo => |i| {
            if (i.xattr_idx != 0xFFFFFFFF) xattr_idx = i.xattr_idx;

            mode = DT.FIFO;
        },
        .ext_socket => |i| {
            if (i.xattr_idx != 0xFFFFFFFF) xattr_idx = i.xattr_idx;

            mode = DT.SOCK;
        },
        else => unreachable,
    }

    const sentinel_path = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(sentinel_path);

    const res = std.os.linux.mknod(sentinel_path, mode, dev);
    if (res != 0)
        return error.MknodError;

    try setMetadata(alloc, io, id_table, xattr_table, inode, path, options, xattr_idx);
}

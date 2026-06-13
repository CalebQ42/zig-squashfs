const std = @import("std");
const Io = std.Io;

const DataExtractor = @import("data/extractor.zig");
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
    const path = std.mem.trim(ext_loc, "/");

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

    var loop = io.async(io, finishLoop, .{ alloc, io, &sel, &id_table, &xattr_table, options });

    var cache: Cache = .init(alloc, data, decomp);
    defer cache.deinit();

    var frag_table: Lookup.Table(Lookup.FragEntry) = .init(alloc, data, decomp, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    switch (inode.hdr.type) {
        .file, .ext_file => try sel.async(
            .path,
            extractFile,
            .{ alloc, io, data, decomp, &cache, &frag_table, inode, path, true },
        ),
        .dir, .ext_dir => try sel.async(
            .path,
            extractDir,
            .{ alloc, io, super, data, decomp, &sel, &cache, &frag_table, inode, path, true },
        ),
        .symlink, .ext_symlink => try sel.async(
            .void,
            extractSymlink,
            .{ alloc, io, inode, path, true },
        ),
        else => try sel.async(
            .path,
            extractNod,
            .{ alloc, io, inode, path, true },
        ),
    }

    try loop.await(io);
}

fn finishLoop(alloc: std.mem.Allocator, io: Io, id_table: *Lookup.Table(u16), xattr_table: *XattrTable, options: ExtractionOptions) !void {}

fn extractFile(
    alloc: std.mem.Allocator,
    io: Io,
    data: []u8,
    decomp: Decomp.Fn,
    cache: *Cache,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    inode: Inode,
    path: []const u8,
    origin: bool,
) Error!PathReturn {
    defer if (!origin) inode.deinit(alloc);
    errdefer alloc.free(path);

    try io.checkCancel();

    var ret: PathReturn = .{
        .hdr = inode.hdr,
        .path = path,
    };

    var ext: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var rdr: DataExtractor = .init(data, decomp, super.block_size, f.blocks, f.size, f.block_start);
            rdr.addCache(cache);

            if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

            const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
            if (entry.size.uncompressed) {
                rdr.addFrag(data[entry.block_start..][0..entry.size.size]);
            } else {
                rdr.addFrag(try cache.get(io, entry.block_start, entry.size));
            }
        },
        .ext_file => |f| blk: {
            if (f.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = f.xattr_idx;

            var rdr: DataExtractor = .init(data, decomp, super.block_size, f.blocks, f.size, f.block_start);
            rdr.addCache(cache);

            if (f.frag_idx == 0xFFFFFFFF) break :blk rdr;

            const entry: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
            if (entry.size.uncompressed) {
                rdr.addFrag(data[entry.block_start..][0..entry.size.size]);
            } else {
                rdr.addFrag(try cache.get(io, entry.block_start, entry.size));
            }
        },
        else => unreachable,
    };

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    try ext.extractAsync(alloc, io, atomic.file);

    try atomic.link(io);

    return ret;
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
    errdefer alloc.free(path);

    var ret: PathReturn = .{
        .hdr = inode.hdr,
        .path = path,
    };

    try Io.Dir.cwd().createDirPath(io, path);

    var dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadataReader = .init(alloc, data, decomp, d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk Directory.init(alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            if (d.xattr_idx != 0xFFFFFFFF) ret.xattr_idx = d.xattr_idx;

            var meta: MetadataReader = .init(alloc, data, decomp, d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk Directory.init(alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(alloc);

    for (dir.entries) |entry| {
        var new_inode: Inode = try .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry);

        const new_path = std.mem.concat(alloc, &.{ path, "/", entry.name }) catch |err| {
            new_inode.deinit(alloc);
            return err;
        };

        sel.async();
    }
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

// Types

const ReturnUnion = union(enum) {
    path: Error!PathReturn,
    dir: Error!PathReturn,
    void: Error!void,
};

const Error = error{} || Decomp.Error || Directory.Error || DataExtractor.Error;

const PathReturn = struct {
    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: ?u32 = null,
};

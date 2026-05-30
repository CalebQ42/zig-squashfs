const std = @import("std");
const Io = std.Io;

const Atomic = std.atomic.Value;

const DecompCache = @import("decomp_cache.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const Superblock = @import("archive.zig").Superblock;
const Directory = @import("directory.zig");
const DataExtractor = @import("data/extractor.zig");
const DataReader = @import("data/reader.zig");
const Lookup = @import("lookup.zig");

pub fn extract(alloc: std.mem.Allocator, io: Io, inode: Inode, cache: *DecompCache, super: Superblock, ext_loc: []const u8, options: ExtractionOptions) !void {
    const path = std.mem.trim(u8, ext_loc, "/");

    var buf: [50]ReturnUnion = undefined;
    var sel: Io.Select(ReturnUnion) = .init(io, &buf);

    defer {
        while (sel.cancel()) |ret| {
            switch (ret) {
                .dir_ret => |d| {
                    const res = d catch continue;
                    alloc.free(res.path);
                },
                .file_ret => |f| {
                    const res = f catch continue;
                    alloc.free(res.path);
                },
                else => {},
            }
        }
    }

    var frag_table: Lookup.Table(Lookup.FragmentEntry) = .init(alloc, cache, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    var ret_loop = io.async(returnLoop, .{ alloc, &sel, options });

    try extractReal(alloc, io, cache, super, &sel, &frag_table, path, inode, null, false);

    ret_loop.await(io) catch |err| {
        // TODO: Drain sel
        return err;
    };
}

fn extractReal(
    alloc: std.mem.Allocator,
    io: Io,
    cache: *DecompCache,
    super: Superblock,
    sel: *Io.Select(ReturnUnion),
    frag_table: *Lookup.Table(Lookup.FragmentEntry),
    path: []const u8,
    inode: Inode,
    parent: ?*Atomic(usize),
    origin: bool,
) Error!void {
    try io.checkCancel();

    switch (inode.data) {
        .dir, .ext_dir => sel.async(
            .dir_ret,
            extractDir,
            .{ alloc, io, cache, super, sel, frag_table, path, inode, parent, origin },
        ),
        .file, .ext_file => sel.async(
            .file_ret,
            extractFile,
            .{ alloc, io, cache, super.block_size, frag_table, path, inode, parent, origin },
        ),
        else => return error.Canceled,
    }
}

fn extractDir(
    alloc: std.mem.Allocator,
    io: Io,
    cache: *DecompCache,
    super: Superblock,
    sel: *Io.Select(ReturnUnion),
    frag_table: *Lookup.Table(Lookup.FragmentEntry),
    path: []const u8,
    inode: Inode,
    parent: ?*Atomic(usize),
    origin: bool,
) Error!DirReturn {
    defer {
        if (parent != null)
            _ = parent.?.fetchSub(1, .acquire);
        if (!origin) inode.deinit(alloc);
    }
    errdefer if (!origin) alloc.free(path);

    const dir = inode.directory(alloc, io, cache, super.dir_start) catch |err| switch (err) {
        error.NotDirectory => unreachable,
        else => |e| return e,
    };
    defer dir.deinit(alloc);

    const sub_files = try alloc.create(Atomic(usize));
    sub_files.* = .init(dir.entries.len);

    const ret: DirReturn = .{
        .path = path,
        .sub_files = sub_files,
        .origin = origin,

        .uid_idx = inode.hdr.uid_idx,
        .gid_idx = inode.hdr.gid_idx,
        .mod_time = inode.hdr.mod_time,
        .permissions = inode.hdr.permission,

        .xattr_idx = switch (inode.data) {
            .ext_dir => |d| if (d.xattr_idx != 0xFFFFFFFF) d.xattr_idx else null,
            else => null,
        },
    };

    for (dir.entries) |entry| {
        const new_inode: Inode = try .initDirEntry(alloc, io, cache, super.inode_start, super.block_size, entry);
        errdefer new_inode.deinit(alloc);

        const new_path = try std.mem.concat(alloc, u8, &.{ path, "/", entry.name });

        try extractReal(
            alloc,
            io,
            cache,
            super,
            sel,
            frag_table,
            new_path,
            new_inode,
            sub_files,
            false,
        );
    }
    return ret;
}
fn extractFile(
    alloc: std.mem.Allocator,
    io: Io,
    cache: *DecompCache,
    block_size: u32,
    frag_table: *Lookup.Table(Lookup.FragmentEntry),
    path: []const u8,
    inode: Inode,
    parent: ?*Atomic(usize),
    origin: bool,
) Error!FileReturn {
    defer {
        if (parent != null)
            _ = parent.?.fetchSub(1, .acquire);
        if (!origin) inode.deinit(alloc);
    }
    errdefer if (!origin) alloc.free(path);

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    var ret: FileReturn = .{
        .path = path,
        .origin = origin,

        .uid_idx = inode.hdr.uid_idx,
        .gid_idx = inode.hdr.gid_idx,
        .permissions = inode.hdr.permission,
        .mod_time = inode.hdr.mod_time,
    };

    const data: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var data: DataExtractor = .init(cache, block_size, f.size, f.data_start, f.blocks);
            if (f.frag_idx != 0xFFFFFFFF) {
                const entry: Lookup.FragmentEntry = try frag_table.get(io, f.frag_idx);
                if (entry.size.uncompressed) {
                    data.addFragment(cache.map.memory[entry.start..][0..entry.size.size], f.frag_offset);
                } else {
                    const block = try cache.get(io, entry.start, entry.size.size, block_size);
                    data.addFragment(block, f.frag_offset);
                }
            }
            break :blk data;
        },
        .ext_file => |f| blk: {
            var data: DataExtractor = .init(cache, block_size, f.size, f.data_start, f.blocks);
            if (f.frag_idx != 0xFFFFFFFF) {
                const entry: Lookup.FragmentEntry = try frag_table.get(io, f.frag_idx);
                if (entry.size.uncompressed) {
                    data.addFragment(cache.map.memory[entry.start..][0..entry.size.size], f.frag_offset);
                } else {
                    const block = try cache.get(io, entry.start, entry.size.size, block_size);
                    data.addFragment(block, f.frag_offset);
                }
            }
            if (f.xattr_idx != 0xFFFFFFFF)
                ret.xattr_idx = f.xattr_idx;
            break :blk data;
        },
        else => unreachable,
    };
    try data.asyncExtract(io, atomic.file);

    try atomic.link(io);

    return ret;
}

// Loop

fn returnLoop(alloc: std.mem.Allocator, sel: *Io.Select(ReturnUnion), options: ExtractionOptions) !void {
    while (true) {
        const finished = try sel.await();

        switch (finished) {
            .dir_ret => |d| {
                const ret = try d;
                if (ret.sub_files.load(.unordered) != 0) {
                    sel.queue.putOne(sel.io, .{ .dir_ret = ret }) catch |err| {
                        if (!ret.origin) alloc.free(ret.path);
                        return err;
                    };
                    continue;
                }
                if (!ret.origin) alloc.free(ret.path);
                alloc.destroy(ret.sub_files);

                if (!options.ignore_permissions and !options.ignore_xattr) {
                    // TODO: set permissions & xattr.
                }
            },
            .file_ret => |f| {
                const ret = try f;
                if (!ret.origin) alloc.free(ret.path);

                if (!options.ignore_permissions and !options.ignore_xattr) {
                    // TODO: set permissions & xattr.
                }
            },
            .void_ret => |v| try v,
        }

        if (sel.group.token.load(.unordered) == null) break;
    }
}

// Utility types

const ReturnUnion = union(enum) {
    file_ret: Error!FileReturn,
    dir_ret: Error!DirReturn,
    void_ret: Error!void,
};

const Error = error{Canceled} || Directory.Error || Io.Dir.CreateFileAtomicError || Io.File.Atomic.LinkError || DataExtractor.Error;

const FileReturn = struct {
    path: []const u8,
    origin: bool,

    uid_idx: u32,
    gid_idx: u32,
    mod_time: u32,
    permissions: u16,

    xattr_idx: ?u32 = null,
};
const DirReturn = struct {
    path: []const u8,
    sub_files: *Atomic(usize),
    origin: bool,

    uid_idx: u32,
    gid_idx: u32,
    mod_time: u32,
    permissions: u16,

    xattr_idx: ?u32 = null,
};

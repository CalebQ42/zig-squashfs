const std = @import("std");
const Io = std.Io;

const Super = @import("../archive.zig").Super;
const Inode = @import("../inode.zig");
const Options = @import("../options.zig");
const Lookup = @import("../lookup.zig");
const FragCache = @import("../frag_cache.zig");
const MetadataReader = @import("../utils/meta.zig");
const Directory = @import("../dir.zig");
const DataExtractor = @import("../utils/data_extractor.zig");
const Common = @import("common.zig");

pub fn extract(alloc: std.mem.Allocator, io: Io, data: []u8, super: Super, inode: Inode, filepath: []const u8, options: Options) !void {
    const path = std.mem.trim(u8, filepath, "/");

    var id_table: Lookup.Table(u16) = try .init(data, super.decomp_fn, super.id_table_start, super.id_count);
    defer id_table.deinit(alloc);
    var xattr_table: Lookup.Xattr = try .init(data, super.decomp_fn, super.xattr_table_start);
    defer xattr_table.deinit(alloc);
    var frag_cache: FragCache = try .init(data, super.decomp_fn, super.block_size, super.frag_table_start, super.frag_count);
    defer frag_cache.deinit(alloc);

    var cwd = Io.Dir.cwd();

    if (inode.header.type != .dir and inode.header.type != .ext_dir)
        return workFn(alloc, io, cwd, data, super, &id_table, &xattr_table, &frag_cache, inode, path, options, true);

    var dirs: std.ArrayList(Common.InodeAndPath) = try .initCapacity(alloc, 10);
    dirs.appendAssumeCapacity(.{
        .inode = inode,
        .path = path,
        .root = true,
    });
    defer {
        while (dirs.pop()) |dir|
            if (dir.path.len != path.len) alloc.free(dir.path);
        dirs.deinit(alloc);
    }

    var group: Io.Group = .init;
    defer group.cancel(io);

    var res_err: ?anyerror = null;

    var i: usize = 0;
    while (i < dirs.items.len) {
        if (res_err != null) return res_err.?;

        defer i += 1;

        std.debug.print("YO: {s}\n", .{dirs.items[i].path});

        const in = dirs.items[i];
        const d = in.inode.data.dir;
        try cwd.createDirPath(io, in.path);

        if (d.size <= 3) {
            defer if (!in.root)
                in.deinit(alloc);

            var fil = try cwd.openFile(io, in.path, .{});
            defer fil.close(io);

            try Common.applyPermissions(alloc, io, &id_table, &xattr_table, in.inode.header, d.xattr_idx, fil, options);
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

            if (new_inode.header.type == .dir or new_inode.header.type == .ext_dir) {
                dirs.append(alloc, .{
                    .inode = new_inode,
                    .path = new_path,
                    .root = false,
                }) catch |err| {
                    alloc.free(new_path);
                    new_inode.deinit(alloc);
                    return err;
                };
                continue;
            }

            group.async(io, groupFn, .{
                alloc,
                io,
                cwd,
                data,
                super,
                &id_table,
                &xattr_table,
                &frag_cache,
                new_inode,
                new_path,
                options,
                false,
                &res_err,
            });
        }

        try dirs.append(alloc, in);
    }
    std.debug.print("end\n", .{});

    try group.await(io);

    while (dirs.pop()) |dir| {
        defer if (dir.path.len != path.len)
            alloc.free(dir.path);

        var fil = try cwd.openFile(io, dir.path, .{});
        defer fil.close(io);

        try Common.applyPermissions(alloc, io, &id_table, &xattr_table, dir.inode.header, dir.inode.data.dir.xattr_idx, fil, options);
    }
}

fn groupFn(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    data: []u8,
    super: Super,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    frag_cache: *FragCache,
    inode: Inode,
    path: []const u8,
    options: Options,
    root: bool,
    res_err: *?anyerror,
) Io.Cancelable!void {
    if (res_err.* == null)
        return;
    workFn(alloc, io, cwd, data, super, id_table, xattr_table, frag_cache, inode, path, options, root) catch |err| {
        res_err.* = err;
        return;
    };
}
fn workFn(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    data: []u8,
    super: Super,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    frag_cache: *FragCache,
    inode: Inode,
    path: []const u8,
    options: Options,
    root: bool,
) !void {
    switch (inode.data) {
        .file => |f| {
            defer if (!root) {
                inode.deinit(alloc);
                alloc.free(path);
            };

            var atomic = try cwd.createFileAtomic(io, path, .{});
            defer atomic.deinit(io);

            // var ext: DataExtractor = try .init(alloc, data[f.start..], super.decomp_fn, super.block_size, f.size, f.blocks);

            // if (f.frag_idx != 0xFFFFFFFF) {
            //     const frag = try frag_cache.get(alloc, io, f.frag_idx);
            //     ext.addFrag(frag[f.frag_offset..][0 .. f.size % super.block_size]);
            // }

            // try ext.extract(alloc, io, atomic.file);

            const DataReader = @import("../utils/data_reader.zig");

            var ext: DataReader = try .init(alloc, data[f.start..], super.decomp_fn, super.block_size, f.size, f.blocks);
            defer ext.deinit();

            if (f.frag_idx != 0xFFFFFFFF) {
                const frag = try frag_cache.get(alloc, io, f.frag_idx);
                ext.addFrag(frag[f.frag_offset..][0 .. f.size % super.block_size]);
            }

            var buf: [512]u8 = undefined;
            var wrt = atomic.file.writer(io, &buf);
            _ = try ext.interface.streamRemaining(&wrt.interface);
            try wrt.flush();

            try Common.applyPermissions(alloc, io, id_table, xattr_table, inode.header, f.xattr_idx, atomic.file, options);

            try atomic.link(io);
        },
        .symlink => |s| try Common.symlink(alloc, io, cwd, s, path, root),
        .dev => |d| try Common.device(alloc, io, cwd, id_table, xattr_table, inode.header, d, path, options, root),
        .fifo => |f| try Common.fifo(alloc, io, cwd, id_table, xattr_table, inode.header, f, path, options, root),
        .dir => unreachable,
    }
}

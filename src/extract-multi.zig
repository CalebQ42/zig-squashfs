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
const Atomic = std.atomic.Value;

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

    var atomic_err: Atomic(?Error) = .init(null);

    var future = switch (inode.hdr.type) {};

    _ = io;
    _ = inode;
    _ = options;
    _ = path;

    return error.TODO;
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
    origin: bool,
    atomic_err: *Atomic(?Error),
) error{Canceled}!void {
    defer if (!origin) alloc.free(path);

    var xattr_idx: u32 = 0xFFFFFFFF;

    Io.Dir.cwd().createDirPath(io, path, .{}) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.store(e, .unordered);
            return;
        },
    };

    var group: Io.Group = blk: {
        var dir: Directory = switch (inode.data) {
            .dir => |d| d_blk: {
                var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
                meta.interface.discardAll(d.block_offset) catch |err| break :blk err;

                break :d_blk .init(alloc, &meta.interface, d.size) catch |err| break :blk err;
            },
            .ext_dir => |d| d_blk: {
                xattr_idx = d.xattr_idx;

                var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
                meta.interface.discardAll(d.block_offset) catch |err| break :blk err;

                break :d_blk .init(alloc, &meta.interface, d.size) catch |err| break :blk err;
            },
            else => unreachable,
        };
        defer dir.deinit(alloc);

        var group: Io.Group = .init;

        for (dir.entries) |entry| {
            var new_inode: Inode = .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry) catch |err| {
                group.cancel(io);
                break :blk err;
            };

            const new_path = std.mem.concat(alloc, u8, &.{ path, "/", entry.name }) catch |err| {
                new_inode.deinit(alloc);
                group.cancel(io);
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
                    new_inode,
                    new_path,
                    options,
                    false,
                    atomic_err,
                }),
                .file => {},
                .symlink => {},
                else => {},
            }
        }
    } catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.store(e, .unordered);
            return;
        },
    };

    try group.await(io);

    setMetadata(alloc, io, id_table, xattr_table, inode, path, options, xattr_idx) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return error.Canceled;
        },
        else => |e| {
            atomic_err.store(e, .unordered);
            return;
        },
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
    xattr_idx: u32,
) !void {
    if (options.ignore_permissions and (options.ignore_xattr or xattr_idx == null)) return;

    var fil: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer fil.close(io);

    if (!options.ignore_xattr and xattr_idx != 0xFFFFFFFF) {
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

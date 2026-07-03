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

    var common: ExtractCommon = .init(alloc, super, data, decomp, options);
    defer common.deinit(io);

    common.start(alloc, io, inode, path, null);

    try common.group.await(io);
}

fn extractDir(
    alloc: std.mem.Allocator,
    io: Io,
    common: *ExtractCommon,
    inode: Inode,
    path: []const u8,
    parent: ?*DirReturn,
) Error!void {
    var xattr_idx: u32 = 0xFFFFFFFF;

    try Io.Dir.cwd().createDirPath(io, path);

    var dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadataReader = .init(alloc, common.data, common.decomp, d.block_start + common.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            xattr_idx = d.xattr_idx;

            var meta: MetadataReader = .init(alloc, common.data, common.decomp, d.block_start + common.dir_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try Directory.init(alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(alloc);

    if (dir.entries.len == 0) {
        defer if (parent != null) {
            alloc.free(path);
            parent.?.finish(alloc);
        };
        try setMetadata(alloc, io, common, inode, path, xattr_idx);
        return;
    }

    var dir_ret: *DirReturn = try .init(common.dir_alloc.allocator(), inode.hdr, path, xattr_idx, dir.entries.len, parent);
    errdefer dir_ret.deinit(common.dir_alloc.allocator());

    for (dir.entries) |entry| {
        const new_inode: Inode = try .initEntry(alloc, common.data, common.decomp, common.inode_start, common.block_size, entry);

        const new_path = std.mem.concat(u8, &.{ path, "/", entry.name }) catch |err| {
            new_inode.deinit(alloc);
            return err;
        };

        common.start(alloc, io, new_inode, new_path, dir_ret);
    }
}

fn setMetadata(
    alloc: std.mem.Allocator,
    io: Io,
    common: *ExtractCommon,
    inode: Inode,
    path: []const u8,
    xattr_idx: u32,
) Error!void {
    if (common.options.ignore_permissions and (common.options.ignore_xattr or xattr_idx == null)) return;

    var fil: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer fil.close(io);

    if (!common.options.ignore_xattr and xattr_idx != null) {
        const xattr = try common.xattr_table.get(alloc, io, xattr_idx.?);
        defer xattr.deinit(alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return error.SetXattrError;
        }
    }
    if (!common.options.ignore_permissions) {
        try fil.setTimestamps(io, .{
            .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(@as(i96, @intCast(inode.hdr.mod_time)) * std.time.ns_per_s)),
        });
        try fil.setPermissions(io, @enumFromInt(inode.hdr.permissions));
        try fil.setOwner(
            io,
            try common.id_table.get(io, inode.hdr.uid_idx),
            try common.id_table.get(io, inode.hdr.gid_idx),
        );
    }
}

// Types

const Error = error{ MknodError, SetXattrError } || Io.Dir.CreateDirPathError || Io.Reader.StreamError || Directory.Error;

const DirReturn = struct {
    common: *ExtractCommon,

    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: u32 = 0xFFFFFFFF,

    atomic: Atomic(u32),

    parent: ?*DirReturn,

    fn init(alloc: std.mem.Allocator, hdr: Inode.Header, path: []const u8, xattr_idx: u32, sub_files: u32, parent: ?*DirReturn) !*DirReturn {
        const out = try alloc.create(DirReturn);

        out.* = .{
            .hdr = hdr,
            .path = path,
            .xattr_idx = xattr_idx,

            .atomic = .init(sub_files),

            .parent = parent,
        };

        return out;
    }
    fn deinit(self: *DirReturn, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    fn finish(self: *DirReturn, alloc: std.mem.Allocator) !void {
        if (self.atomic.fetchSub(1, .release) != 0) return;

        defer self.deinit(alloc);
    }
};

const ExtractCommon = struct {
    group: Io.Group,
    dir_alloc: std.heap.ArenaAllocator,

    data: []u8,
    decomp: Decomp.Fn,

    dir_start: u64,
    inode_start: u64,
    block_size: u32,

    id_table: Lookup.Table(u16),
    xattr_table: XattrTable,
    frag_table: Lookup.Table(Lookup.FragEntry),
    cache: Cache,

    options: ExtractionOptions,

    fn init(alloc: std.mem.Allocator, super: Superblock, data: []u8, decomp: Decomp.Fn, options: ExtractionOptions) ExtractCommon {
        return .{
            .group = .init,
            .dir_alloc = .init(alloc),

            .data = data,
            .decomp = decomp,

            .dir_start = super.dir_start,
            .inode_start = super.inode_start,
            .block_size = super.block_size,

            .id_table = .init(alloc, data, decomp, super.id_start, super.id_count),
            .xattr_table = .init(alloc, data, decomp, super.xattr_start),
            .frag_table = .init(alloc, data, decomp, super.frag_start, super.frag_count),
            .cache = .init(alloc, data, decomp),

            .options = options,
        };
    }
    fn deinit(self: *ExtractCommon, io: Io) void {
        self.group.cancel(io);
        self.dir_alloc.deinit();
        self.id_table.deinit();
        self.xattr_table.deinit();
        self.frag_table.deinit();
        self.cache.deinit();
    }

    fn start(self: *ExtractCommon, alloc: std.mem.Allocator, io: Io, inode: Inode, path: []const u8, parent: ?*DirReturn) void {
        switch (inode.hdr.type) {
            .dir, .ext_dir => self.group.async(io, extractDir, .{ alloc, io, self, inode, path, parent }),
            .file, .ext_file => {},
            .symlink, .ext_symlink => {},
            else => {},
        }
    }
};

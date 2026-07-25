const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;

const DataExtractor = @import("data/extractor.zig");
const Decomp = @import("decomp.zig");
const Directory = @import("directory.zig");
const ExtractionOption = @import("options.zig");
const Inode = @import("inode.zig");
const Lookup = @import("lookup.zig");
const MetadataReader = @import("meta_rdr.zig");
const Superblock = @import("archive.zig").Superblock;
const Cache = @import("util/cache.zig");
const XattrTable = @import("xattr.zig");

pub fn extract(alloc: std.mem.Allocator, io: Io, super: Superblock, data: []u8, decomp: Decomp.Fn, inode: Inode, filepath: []const u8, options: ExtractionOption) !void {
    const path = std.mem.trim(u8, filepath, "/");

    var frag_table: Lookup.Table(Lookup.FragEntry) = .init(alloc, data, decomp, super.frag_start, super.frag_count);
    defer frag_table.deinit();

    var id_table: Lookup.Table(u16) = .init(alloc, data, decomp, super.id_start, super.id_count);
    defer id_table.deinit();

    var xattr_table: XattrTable = .init(alloc, data, decomp, super.xattr_start);
    defer xattr_table.deinit();

    var cache: Cache = .init(alloc, data, decomp);
    defer cache.deinit();

    var err: ?Error = null;
    var group: Io.Group = .init;

    group.async(
        io,
        groupExtract,
        .{ alloc, io, data, decomp, super, &group, &frag_table, &id_table, &xattr_table, &cache, &err, inode, path, options, null },
    );
}

fn groupExtract(
    alloc: std.mem.Allocator,
    io: Io,
    data: []u8,
    decomp: Decomp.Fn,
    super: Superblock,
    group: *Io.Group,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    cache: *Cache,
    err: *?Error,
    inode: Inode,
    path: []const u8,
    options: ExtractionOption,
    parent: ?*Parent,
) error{Canceled}!void {
    if (err != null) {
        if (parent != null) {
            alloc.free(path);
            inode.deinit(alloc);
            parent.?.finish(alloc, io);
        }
        return;
    }
    switch (inode.hdr.type) {
        .dir, .ext_dir => group.async(io, extractDir, .{ alloc, io, data, decomp, super, group, frag_table, id_table, xattr_table, cache, inode, path, options, parent }),
        .file, .ext_file => group.async(io, extractReg, .{ alloc, io, data, decomp, super.block_size, group, frag_table, cache, inode, path, options, parent }),
        .symlink, .ext_symlink => group.async(io, extractSymlink, .{ alloc, io, inode, path, parent }),
        else => group.async(io, extractNod, .{ alloc, io, id_table, xattr_table, inode, path, options, parent }),
    }
}

fn extractDir(
    alloc: std.mem.Allocator,
    io: Io,
    data: []u8,
    decomp: Decomp.Fn,
    super: Superblock,
    group: *Io.Group,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    cache: *Cache,
    err: *?Error,
    inode: Inode,
    path: []const u8,
    options: ExtractionOption,
    parent: ?*Parent,
) Error!void {
    var xattr_idx: u32 = 0xFFFFFFFF;

    const dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try .init(alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            xattr_idx = d.xattr_idx;

            var meta: MetadataReader = .init(alloc, data, decomp, super.dir_start + d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try .init(alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(alloc);

    try Io.Dir.cwd().createDirPath(io, path);

    if (dir.entries.len == 0) {
        try setMetadataPath(alloc, io, inode.hdr, id_table, xattr_table, path, xattr_idx, options);
        if (parent != null) {
            try parent.?.finish(io);
        }
        return;
    }

    const cur_dir = try Parent.create(alloc, id_table, xattr_table, err, inode.hdr, path, options, parent, xattr_idx, dir.entries);

    for (dir.entries) |entry| {
        const new_inode: Inode = try .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry);

        const new_path = std.mem.concat(alloc, u8, &.{ path, "/", entry.name }) catch |e| {
            new_inode.deinit(alloc);
            return e;
        };

        group.async(
            io,
            groupExtract,
            .{ alloc, io, data, decomp, super, group, frag_table, id_table, xattr_table, cache, err, new_inode, new_path, options, cur_dir },
        );
    }
}
fn extractReg(
    alloc: std.mem.Allocator,
    io: Io,
    data: []u8,
    decomp: Decomp.Fn,
    block_size: u32,
    group: *Io.Group,
    frag_table: *Lookup.Table(Lookup.FragEntry),
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    cache: *Cache,
    err: *?Error,
    inode: Inode,
    path: []const u8,
    options: ExtractionOption,
    parent: ?*Parent,
) Error!void {
    var blocks: usize = 0;
    var xattr_idx: u32 = 0xFFFFFFFF;

    var ext: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var ext: DataExtractor = .init(data, decomp, block_size, f.blocks, f.block_start, f.size);
            blocks = f.blocks.len;

            if (f.frag_idx != 0xFFFFFFFF) {
                blocks += 1;
                const frag: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
                if (frag.size.uncompressed) {
                    ext.addFrag(data[frag.block_start..][0..frag.size.size], f.frag_offset);
                } else {
                    const frag_block = try cache.get(io, frag.block_start, frag.size.size);
                    ext.addFrag(frag_block, f.frag_offset);
                }
            }
            break :blk ext;
        },
        .ext_file => |f| blk: {
            xattr_idx = f.xattr_idx;

            var ext: DataExtractor = .init(data, decomp, block_size, f.blocks, f.block_start, f.size);
            blocks = f.blocks.len;

            if (f.frag_idx != 0xFFFFFFFF) {
                blocks += 1;
                const frag: Lookup.FragEntry = try frag_table.get(io, f.frag_idx);
                if (frag.size.uncompressed) {
                    ext.addFrag(data[frag.block_start..][0..frag.size.size], f.frag_offset);
                } else {
                    const frag_block = try cache.get(io, frag.block_start, frag.size.size);
                    ext.addFrag(frag_block, f.frag_offset);
                }
            }
            break :blk ext;
        },
        else => unreachable,
    };

    const fin = try FileFinish.create(alloc, io, id_table, xattr_table, err, inode.hdr, path, options, parent, xattr_idx, blocks);

    try ext.extractAsync(alloc, io, group, fin);
}
fn extractSymlink(alloc: std.mem.Allocator, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) Error!void {
    defer if (parent != null) {
        inode.deinit(alloc);
        alloc.free(path);
    };

    const target = switch (inode.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };

    try Io.Dir.cwd().symLink(io, target, path, .{});

    if (parent != null)
        parent.?.finish(io);
}
fn extractNod(
    alloc: std.mem.Allocator,
    io: Io,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    inode: Inode,
    path: []const u8,
    parent: ?*Parent,
    options: ExtractionOption,
) Error!void {
    var xattr_idx: u32 = 0xFFFFFFFF;
    var device: u32 = 0;
    var mode: u32 = undefined;

    const DT = std.os.linux.DT;

    switch (inode.data) {
        .block_dev => |d| {
            mode = DT.BLK;
            device = d.device;
        },
        .ext_block_dev => |d| {
            mode = DT.BLK;
            device = d.device;
            xattr_idx = d.xattr_idx;
        },
        .char_dev => |d| {
            mode = DT.CHR;
            device = d.device;
        },
        .ext_char_dev => |d| {
            mode = DT.CHR;
            device = d.device;
            xattr_idx = d.xattr_idx;
        },
        .fifo => {
            mode = DT.FIFO;
        },
        .ext_fifo => |f| {
            mode = DT.FIFO;
            xattr_idx = f.xattr_idx;
        },
        .socket => {
            mode = DT.SOCK;
        },
        .ext_socket => |s| {
            mode = DT.SOCK;
            xattr_idx = s.xattr_idx;
        },
        else => unreachable,
    }

    const sentinel_path = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(sentinel_path);

    const res = std.os.linux.mknod(sentinel_path, mode, device);
    if (res != 0)
        return Error.Mknod;

    try setMetadataPath(alloc, io, inode.hdr, id_table, xattr_table, path, xattr_idx, options);

    if (parent != null)
        try parent.?.finish(io);
}

fn setMetadataPath(
    alloc: std.mem.Allocator,
    io: Io,
    hdr: Inode.Header,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    path: []const u8,
    xattr_idx: u32,
    options: ExtractionOption,
) Error!void {
    if (options.ignore_permissions and (options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return setMetadata(alloc, io, hdr, id_table, xattr_table, file, xattr_idx, options);
}
fn setMetadata(
    alloc: std.mem.Allocator,
    io: Io,
    hdr: Inode.Header,
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    file: Io.File,
    xattr_idx: u32,
    options: ExtractionOption,
) Error!void {
    if (options.ignore_permissions and (options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    if (!options.ignore_xattr and xattr_idx != 0xFFFFFFFF) {
        var xattr = try xattr_table.get(alloc, io, xattr_idx);
        defer xattr.deinit(alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(file.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return Error.SetXattr;
        }
    }

    if (options.ignore_permissions) return;

    try file.setTimestamps(io, .{
        .modify_timestamp = .init(
            Io.Timestamp.fromNanoseconds(@as(i96, @intCast(hdr.mod_time)) * std.time.ns_per_s),
        ),
    });
    try file.setPermissions(io, @enumFromInt(hdr.permissions));
    try file.setOwner(io, try id_table.get(io, hdr.uid_idx), try id_table.get(io, hdr.gid_idx));
}

// Types

pub const Error = error{ Mknod, SetXattr } || std.mem.Allocator.Error || Io.Cancelable || Io.Reader.Error || Io.Dir.CreateDirPathError || Cache.Error ||
    Io.File.SetPermissionsError || Io.Dir.SymLinkError || Io.File.SeekError || Io.Writer.Error || Io.File.Atomic.LinkError || Io.ConcurrentError;

const FileFinish = struct {
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    err: *?Error,

    inode: Inode,
    options: ExtractionOption,
    parent: ?*Parent,
    xattr_idx: u32,

    file: Io.File.Atomic,

    atomic: Atomic(usize),
    has_err: bool = false,

    fn create(
        alloc: std.mem.Allocator,
        io: Io,
        id_table: *Lookup.Table(u16),
        xattr_table: *XattrTable,
        err: *?Error,
        hdr: Inode.Header,
        path: []const u8,
        options: ExtractionOption,
        parent: ?*Parent,
        xattr_idx: u32,
        blocks: usize,
    ) Error!*FileFinish {
        const out = try alloc.create(FileFinish);
        out.* = .{
            .id_table = id_table,
            .xattr_table = xattr_table,
            .err = err,

            .hdr = hdr,
            .path = path,
            .options = options,
            .parent = parent,
            .xattr_idx = xattr_idx,

            .file = Io.Dir.cwd().createFileAtomic(io, path, .{}),

            .atomic = .init(blocks),
        };
        return out;
    }

    fn finish(self: *FileFinish, alloc: std.mem.Allocator, io: Io) void {
        if (self.atomic.fetchSub(1, .release) > 0) return;

        defer {
            if (self.parent != null) {
                alloc.free(self.path);
                if (self.has_err)
                    self.parent.?.errFinish(alloc, io)
                else
                    self.parent.?.finish(alloc, io);
            }
            alloc.destroy(self);
        }

        if (self.has_err) return;

        setMetadata(alloc, io, self.hdr, self.id_table, self.xattr_table, self.file, self.xattr_idx, self.options) catch |err| {
            self.has_err = true;
            self.err.* = err;
            return;
        };
        self.file.link(io) catch |err| {
            self.has_err = true;
            self.err.* = err;
            return;
        };

        self.file.deinit(io);
    }
    fn errFinish(self: *FileFinish, alloc: std.mem.Allocator, io: Io) void {
        self.has_err = true;

        if (self.atomic.fetchSub(1, .release) > 0) return;

        if (self.parent != null) {
            alloc.free(self.path);
            self.parent.?.errFinish(alloc, io);
        }
        self.file.deinit(io);
        alloc.destroy(self);
    }
};
const Parent = struct {
    id_table: *Lookup.Table(u16),
    xattr_table: *XattrTable,
    err: *?Error,

    hdr: Inode.Header,
    path: []const u8,
    options: ExtractionOption,
    parent: ?*Parent,
    xattr_idx: u32,

    atomic: Atomic(usize),
    has_err: bool = false,

    fn create(
        alloc: std.mem.Allocator,
        id_table: *Lookup.Table(u16),
        xattr_table: *XattrTable,
        err: *?Error,
        hdr: Inode.Header,
        path: []const u8,
        options: ExtractionOption,
        parent: ?*Parent,
        xattr_idx: u32,
        num: usize,
    ) Error!*Parent {
        const out = try alloc.create(Parent);
        out.* = .{
            .id_table = id_table,
            .xattr_table = xattr_table,
            .err = err,

            .hdr = hdr,
            .path = path,
            .options = options,
            .parent = parent,
            .xattr_idx = xattr_idx,

            .atomic = .init(num),
        };
        return out;
    }

    fn finish(self: *Parent, alloc: std.mem.Allocator, io: Io) void {
        if (self.atomic.fetchSub(1, .release) > 0) return;

        defer {
            if (self.parent != null) {
                alloc.free(self.path);
                if (self.has_err)
                    self.parent.?.errFinish(alloc, io)
                else
                    self.parent.?.finish(alloc, io);
            }
            alloc.destroy(self);
        }

        if (self.has_err) return;

        setMetadataPath(alloc, io, self.hdr, self.id_table, self.xattr_table, self.path, self.xattr_idx, self.options) catch |err| {
            self.has_err = true;
            self.err.* = err;
        };
    }
    fn errFinish(self: *Parent, alloc: std.mem.Allocator, io: Io) void {
        self.has_err = true;

        if (self.atomic.fetchSub(1, .release) > 0) return;

        if (self.parent != null) {
            alloc.free(self.path);
            self.parent.?.errFinish(alloc, io);
        }
        alloc.destroy(self);
    }
};

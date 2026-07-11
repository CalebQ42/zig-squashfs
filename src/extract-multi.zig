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

    var common: Common = .init(alloc, super, data, decomp, options);
    defer common.deinit();

    common.group.async(io, extractAsync, .{ &common, io, inode, path, null });

    try common.group.await(io);

    if (common.err != null)
        return common.err.?;
}

fn extractAsync(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) error{Canceled}!void {
    switch (inode.hdr.type) {
        .dir, .ext_dir => extractDir(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => common.err = err,
        },
        .file, .ext_file => extractReg(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => common.err = err,
        },
        .symlink, .ext_symlink => extractReg(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => common.err = err,
        },
        else => extractNod(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return error.Canceled;
            },
            else => common.err = err,
        },
    }
}
fn extractDir(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) Error!void {
    var xattr_idx: u32 = 0xFFFFFFFF;

    const dir: Directory = switch (inode.data) {
        .dir => |d| blk: {
            var meta: MetadataReader = .init(common.alloc, common.data, common.decomp, d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try .init(common.alloc, &meta.interface, d.size);
        },
        .ext_dir => |d| blk: {
            xattr_idx = d.xattr_idx;

            var meta: MetadataReader = .init(common.alloc, common.data, common.decomp, d.block_start);
            try meta.interface.discardAll(d.block_offset);

            break :blk try .init(common.alloc, &meta.interface, d.size);
        },
        else => unreachable,
    };
    defer dir.deinit(common.alloc);

    try Io.Dir.cwd().createDirPath(io, path);

    if (dir.entries.len == 0) {
        try setMetadataPath(common, io, inode.hdr, path, xattr_idx);
        if (parent != null) {
            try parent.?.finish(io);
            common.alloc.free(path);
        }
        return;
    }

    const cur_dir: *Parent = try .init(common, dir.entries.len, inode.hdr, path, xattr_idx, parent);

    for (dir.entries) |entry| {
        var new_inode: Inode = try .initEntry(common.alloc, common.data, common.decomp, common.inode_start, common.block_size, entry);

        const new_path = std.mem.concat(common.alloc, u8, &.{ path, "/", entry.name }) catch |err| {
            new_inode.deinit(common.alloc);
            return err;
        };

        common.group.async(io, extractAsync, .{ common, io, new_inode, new_path, cur_dir });
    }
}
fn extractReg(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) Error!void {
    var blocks: usize = 0;
    var xattr_idx: u32 = 0xFFFFFFFF;

    var ext: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var ext: DataExtractor = .init(common.data, common.decomp, common.block_size, f.blocks, f.block_start, f.size);
            blocks = f.blocks.len;

            if (f.frag_idx != 0xFFFFFFFF) {
                blocks += 1;
                const frag: Lookup.FragEntry = try common.frag_table.get(io, f.frag_idx);
                if (frag.size.uncompressed) {
                    ext.addFrag(common.data[frag.block_start..][0 .. f.size % common.block_size], f.frag_offset);
                } else {
                    const frag_block = try common.cache.get(io, frag.block_start, frag.size.size);
                    ext.addFrag(frag_block, f.frag_offset);
                }
            }
            break :blk ext;
        },
        .ext_file => |f| blk: {
            xattr_idx = f.xattr_idx;

            var ext: DataExtractor = .init(common.data, common.decomp, common.block_size, f.blocks, f.block_start, f.size);
            blocks = f.blocks.len;

            if (f.frag_idx != 0xFFFFFFFF) {
                blocks += 1;
                const frag: Lookup.FragEntry = try common.frag_table.get(io, f.frag_idx);
                if (frag.size.uncompressed) {
                    ext.addFrag(common.data[frag.block_start..][0 .. f.size % common.block_size], f.frag_offset);
                } else {
                    const frag_block = try common.cache.get(io, frag.block_start, frag.size.size);
                    ext.addFrag(frag_block, f.frag_offset);
                }
            }
            break :blk ext;
        },
        else => unreachable,
    };

    const fin: *FileFinish = try .init(common, io, blocks, inode.hdr, path, xattr_idx, parent);

    ext.extractAsync(common.alloc, io, &common.group, @ptrCast(&common.err), fin);
}
fn extractSymlink(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) Error!void {
    defer if (parent != null) {
        inode.deinit(common.alloc);
        common.alloc.free(path);
    };

    const target = switch (inode.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };

    try Io.Dir.cwd().symLink(io, target, path, .{});

    if (parent != null)
        try parent.?.finish(io);
}
fn extractNod(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Parent) Error!void {
    defer if (parent != null) {};
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

    const sentinel_path = try common.alloc.dupeSentinel(u8, path, 0);
    defer common.alloc.free(sentinel_path);

    const res = std.os.linux.mknod(sentinel_path, mode, device);
    if (res != 0)
        return Error.Mknod;

    try setMetadataPath(common, io, inode.hdr, path, xattr_idx);

    if (parent != null)
        try parent.?.finish(io);
}

fn setMetadataPath(common: *Common, io: Io, hdr: Inode.Header, path: []const u8, xattr_idx: u32) Error!void {
    if (common.options.ignore_permissions and (common.options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return setMetadata(common, io, hdr, file, xattr_idx);
}
fn setMetadata(common: *Common, io: Io, hdr: Inode.Header, file: Io.File, xattr_idx: u32) Error!void {
    if (common.options.ignore_permissions and (common.options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    if (!common.options.ignore_xattr and xattr_idx != 0xFFFFFFFF) {
        var xattr = try common.xattr_table.get(common.alloc, io, xattr_idx);
        defer xattr.deinit(common.alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(file.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return Error.SetXattr;
        }
    }

    if (common.options.ignore_permissions) return;

    try file.setTimestamps(io, .{
        .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(hdr.mod_time * std.time.ns_per_s)),
    });
    try file.setPermissions(io, @enumFromInt(hdr.permissions));
    try file.setOwner(io, try common.id_table.get(io, hdr.uid_idx), try common.id_table.get(io, hdr.gid_idx));
}

// Types

pub const Error = error{ Mknod, SetXattr } || std.mem.Allocator.Error || Io.Cancelable || Io.Reader.Error || Io.Dir.CreateDirPathError || Cache.Error ||
    Io.File.SetPermissionsError || DataExtractor.Error;

pub const Parent = struct {
    common: *Common,

    atomic: Atomic(usize),
    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: u32,

    parent: ?*Parent,

    fn init(common: *Common, len: usize, hdr: Inode.Header, path: []const u8, xattr_idx: u32, parent: ?*Parent) !*Parent {
        const out = try common.arenaAlloc().create(Parent);

        out.* = .{
            .common = common,

            .atomic = .init(len),
            .hdr = hdr,
            .path = path,
            .xattr_idx = xattr_idx,

            .parent = parent,
        };
        return out;
    }

    pub fn finish(self: *Parent, io: Io) Error!void {
        if (self.atomic.fetchSub(1, .release) >= 0) return;

        try setMetadataPath(self.common, io, self.hdr, self.path, self.xattr_idx);

        if (self.parent != null) {
            if (self.hdr.type != .dir and self.hdr.type != .ext_dir)
                self.common.alloc.free(self.path);
            try self.parent.?.finish(io);
        }
    }
};
pub const FileFinish = struct {
    common: *Common,

    atomic: Atomic(usize),
    hdr: Inode.Header,
    file: Io.File.Atomic,
    xattr_idx: u32,

    parent: ?*Parent,

    fn init(common: *Common, io: Io, len: usize, hdr: Inode.Header, path: []const u8, xattr_idx: u32, parent: ?*Parent) !*FileFinish {
        const out = try common.arenaAlloc().create(FileFinish);

        out.* = .{
            .common = common,

            .atomic = .init(len),
            .hdr = hdr,
            .file = try Io.Dir.cwd().createFileAtomic(io, path, .{}),
            .xattr_idx = xattr_idx,

            .parent = parent,
        };
        return out;
    }

    pub fn finish(self: *FileFinish, io: Io) Error!void {
        if (self.atomic.fetchSub(1, .release) >= 0) return;

        defer self.file.deinit(io);

        try setMetadata(self.common, io, self.hdr, self.file.file, self.xattr_idx);

        try self.file.link(io);

        if (self.parent != null) {
            if (self.hdr.type != .dir and self.hdr.type != .ext_dir)
                self.common.alloc.free(self.path);
            try self.parent.?.finish(io);
        }
    }
};

const Common = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    group: Io.Group = .init,
    err: ?Error = null,

    data: []u8,
    decomp: Decomp.Fn,

    inode_start: u64,
    dir_start: u64,
    block_size: u32,

    id_table: Lookup.Table(u16),
    frag_table: Lookup.Table(Lookup.FragEntry),
    xattr_table: XattrTable,
    cache: Cache,

    options: ExtractionOption,

    fn init(alloc: std.mem.Allocator, super: Superblock, data: []u8, decomp: Decomp.Fn, options: ExtractionOption) Common {
        return .{
            .alloc = alloc,
            .arena = .init(alloc),

            .data = data,
            .decomp = decomp,

            .inode_start = super.inode_start,
            .dir_start = super.dir_start,
            .block_size = super.block_size,

            .id_table = .init(alloc, data, decomp, super.id_start, super.id_count),
            .frag_table = .init(alloc, data, decomp, super.frag_start, super.frag_count),
            .xattr_table = .init(alloc, data, decomp, super.xattr_start),
            .cache = .init(alloc, data, decomp),

            .options = options,
        };
    }
    fn deinit(self: *Common) void {
        self.arena.deinit();

        self.id_table.deinit();
        self.frag_table.deinit();
        self.xattr_table.deinit();
        self.cache.deinit();
    }

    fn arenaAlloc(self: *Common) std.mem.Allocator {
        return self.arena.allocator();
    }
};

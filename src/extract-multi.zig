const std = @import("std");
const Io = std.Io;
const Atomic = std.atomic.Value;

const Archive = @import("archive.zig");
const DataExtractor = @import("data/extractor.zig");
const Decomp = @import("decomp.zig");
const Directory = @import("directory.zig");
const ExtractionOption = @import("options.zig");
const Inode = @import("inode.zig");
const Lookup = @import("lookup.zig");
const MetadataReader = @import("meta_rdr.zig");
const XattrTable = @import("xattr.zig");

pub fn extract(alloc: std.mem.Allocator, io: Io, arc: Archive, options: ExtractionOption) !void {
    var common: Common = .init(alloc, arc, options);
    defer common.deinit();
}

fn extractAsync(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Finish) error{Canceled}!void {
    switch (inode.hdr.type) {
        .dir, .ext_dir => extractDir(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel(io);
                return error.Canceled;
            },
            else => common.err = err,
        },
        .file, .ext_file => extractReg(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel(io);
                return error.Canceled;
            },
            else => common.err = err,
        },
        .symlink, .ext_symlink => extractReg(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel(io);
                return error.Canceled;
            },
            else => common.err = err,
        },
        else => extractNod(common, io, inode, path, parent) catch |err| switch (err) {
            error.Canceled => {
                io.recancel(io);
                return error.Canceled;
            },
            else => common.err = err,
        },
    }
}
fn extractDir(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Finish) Error!void {
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
        try setMetadataPath(io, inode.hdr, path, xattr_idx);
        if (parent != null) {
            try parent.?.finish();
            common.alloc.free(path);
        }
        return;
    }

    const cur_dir: *Finish = try .init(common, dir.entries.len, path, xattr_idx, parent);

    for (dir.entries) |entry| {
        var new_inode: Inode = try .initEntry(common.alloc, common.data, common.decomp, common.inode_start, common.block_size, entry);

        const new_path = std.mem.concat(common.alloc, u8, &.{ path, "/", entry.name }) catch |err| {
            new_inode.deinit(common.alloc);
            return err;
        };

        common.group.async(io, extractAsync, .{ common, io, new_inode, new_path, cur_dir });
    }
}
fn extractReg(common: *Common, io: Io, inode: Inode, path: []const u8, parent: ?*Finish) Error!void {
    var blocks: usize = 0;
    var xattr_idx: u32 = 0xFFFFFFFF;

    var ext: DataExtractor = switch (inode.data) {
        .file => |f| blk: {
            var ext: DataExtractor = .init(common.data, common.decomp, common.block_size, f.blocks, f.block_start, f.size);
            blocks = f.blocks.len;

            if (f.frag_idx != 0xFFFFFFFF) {}
        },
        .ext_file => |f| blk: {
            xattr_idx = f.xattr_idx;
        },
        else => unreachable,
    };

    var fin: *Finish = try .init(common, blocks, inode.hdr, path, xattr_idx, parent);
}

fn setMetadataPath(common: *Common, io: Io, hdr: Inode.Header, path: []const u8, xattr_idx: u32) Error!void {
    if (common.options.ignore_permissions and (common.options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.deinit();

    return setMetadata(common, io, hdr, file, xattr_idx);
}
fn setMetadata(common: *Common, io: Io, hdr: Inode.Header, file: Io.File, xattr_idx: u32) Error!void {
    if (common.options.ignore_permissions and (common.options.ignore_xattr or xattr_idx == 0xFFFFFFFF)) return;

    if (!common.options.ignore_xattr and xattr_idx != 0xFFFFFFFF) {
        var xattr = try common.xattr_table.get(common.alloc, io, xattr_idx);
        defer xattr.deinit(common.alloc);

        for (xattr.kvs) |kv| {
            const res = std.os.linux.fsetxattr(file.handle, kv.key, kv.value, kv.value.len, 0);
            if (res != 0)
                return Error.SetXattr;
        }
    }

    if (common.options.ignore_permissions) return;

    try file.setTimestamps(io, .{
        .modify_timestamp = .init(Io.Timestamp.fromNanoseconds(hdr.mod_time * std.time.ns_per_s)),
    });
    try file.setPermissions(io, @enumFromInt(hdr.permissions));
    try file.setOwner(io, try common.id_table.get(hdr.uid_idx), try common.id_table.get(hdr.gid_idx));
}

// Types

const Error = error{ Mknod, SetXattr } || std.mem.Allocator.Error;

pub const Finish = struct {
    common: *Common,

    atomic: Atomic(usize),
    hdr: Inode.Header,
    path: []const u8,
    xattr_idx: u32,

    parent: ?*Finish,

    fn init(common: *Common, len: usize, hdr: Inode.Header, path: []const u8, xattr_idx: u32, parent: ?*Finish) !*Finish {
        const out = try common.dirAlloc().create(Finish);

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

    pub fn finish(self: *Finish, io: Io) Error!void {
        if (self.atomic.fetchSub(1, .unordered) >= 0) return;

        try setMetadataPath(self.common, io, self.hdr, self.path, self.xattr_idx);

        if (self.parent != null) {
            if (self.hdr.type != .dir and self.hdr.type != .ext_dir)
                self.common.alloc.free(self.path);
            try self.parent.?.finish(io);
        }
    }
};

const Common = struct {
    alloc: std.mem.Allocator,
    dir_alloc: std.heap.ArenaAllocator,

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

    options: ExtractionOption,

    fn init(alloc: std.mem.Allocator, arc: Archive, options: ExtractionOption) Common {
        return .{
            .alloc = alloc,
            .dir_alloc = .init(alloc),

            .data = arc.map.memory,
            .decomp = arc.decomp,

            .inode_start = arc.super.inode_start,
            .dir_start = arc.super.dir_start,
            .block_size = arc.super.block_size,

            .id_table = .init(alloc, arc.map.memory, arc.decomp, arc.super.id_start, arc.super.id_count),
            .frag_table = .init(alloc, arc.map.memory, arc.decomp, arc.super.frag_start, arc.super.frag_count),
            .xattr_table = .init(alloc, arc.map.memory, arc.decomp, arc.super.xattr_start),

            .options = options,
        };
    }
    fn deinit(self: *Common) void {
        self.dir_alloc.deinit();

        self.id_table.deinit();
        self.frag_table.deinit();
        self.xattr_table.deinit();
    }

    fn dirAlloc(self: *Common) std.mem.Allocator {
        return self.dir_alloc.allocator();
    }
};

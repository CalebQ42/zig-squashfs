const std = @import("std");
const Io = std.Io;

const Super = @import("../archive.zig").Super;
const Inode = @import("../inode.zig");
const Lookup = @import("../lookup.zig");
const Options = @import("../options.zig");

pub fn symlink(alloc: std.mem.Allocator, io: Io, cwd: Io.Dir, s: Inode.Symlink, path: []const u8, root: bool) !void {
    defer if (!root) {
        s.deinit(alloc);
        alloc.free(path);
    };

    try cwd.symLink(io, s.target, path, .{});
}
pub fn device(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    hdr: Inode.Header,
    d: Inode.Dev,
    path: []const u8,
    options: Options,
    root: bool,
) !void {
    defer if (!root)
        alloc.free(path);

    const mode: u32 = switch (hdr.type) {
        .char_dev, .ext_char_dev => std.os.linux.DT.CHR,
        .block_dev, .ext_block_dev => std.os.linux.DT.BLK,
        else => unreachable,
    };

    const sent_path = try alloc.dupeSentinel(u8, path, 0);

    const res = std.os.linux.mknod(sent_path, mode, d.device);
    alloc.free(sent_path);
    if (res != 0)
        return error.MkNodError;

    var fil = try cwd.openFile(io, path, .{});
    defer fil.close(io);

    try applyPermissions(alloc, io, id_table, xattr_table, hdr, d.xattr_idx, fil, options);
}
pub fn fifo(
    alloc: std.mem.Allocator,
    io: Io,
    cwd: Io.Dir,
    id_table: *Lookup.Table(u16),
    xattr_table: *Lookup.Xattr,
    hdr: Inode.Header,
    f: Inode.Fifo,
    path: []const u8,
    options: Options,
    root: bool,
) !void {
    defer if (!root)
        alloc.free(path);

    const mode: u32 = switch (hdr.type) {
        .fifo, .ext_fifo => std.os.linux.DT.FIFO,
        .socket, .ext_socket => std.os.linux.DT.SOCK,
        else => unreachable,
    };

    const sent_path = try alloc.dupeSentinel(u8, path, 0);

    const res = std.os.linux.mknod(sent_path, mode, 0);
    alloc.free(sent_path);
    if (res != 0)
        return error.MkNodError;

    var fil = try cwd.openFile(io, path, .{});
    defer fil.close(io);

    try applyPermissions(alloc, io, id_table, xattr_table, hdr, f.xattr_idx, fil, options);
}

pub fn applyPermissions(alloc: std.mem.Allocator, io: Io, id_table: *Lookup.Table(u16), xattr_table: *Lookup.Xattr, header: Inode.Header, xattr_idx: ?u32, fil: Io.File, options: Options) !void {
    if (!options.ignore_permissions) {
        try fil.setPermissions(io, @enumFromInt(header.permission));

        try fil.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, @intCast(header.mod_time)) * std.time.ns_per_ms) } });

        try fil.setOwner(io, try id_table.get(alloc, io, header.uid_idx), try id_table.get(alloc, io, header.gid_idx));
    }
    if (!options.ignore_xattr and xattr_idx != null) {
        const xattrs = try xattr_table.get(alloc, io, xattr_idx.?);
        defer {
            for (xattrs) |kv|
                kv.deinit(alloc);
            alloc.free(xattrs);
        }

        for (xattrs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.name, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return error.FSetXattrError;
        }
    }
}

// Utils

pub const InodeAndPath = struct {
    inode: Inode,
    path: []const u8,
    root: bool,

    pub fn deinit(self: InodeAndPath, alloc: std.mem.Allocator) void {
        if (self.root) return;
        self.inode.deinit(alloc);
        alloc.free(self.path);
    }
};

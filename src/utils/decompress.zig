const std = @import("std");
const Io = std.Io;

const Options = @import("../options.zig");
const Inode = @import("../inode.zig");
const Decomp = @import("../decomp.zig");
const Directory = @import("../dir.zig");
const MetadataReader = @import("meta.zig");
const DataReader = @import("data_reader.zig");
const Table = @import("../table.zig");
const Super = @import("../archive.zig").Super;

pub fn single(alloc: std.mem.Allocator, io: Io, data: []const u8, decomp: Decomp.Fn, super: Super, inode: Inode, filepath: []const u8, options: Options) !void {
    const path = std.mem.trim(u8, filepath, "/");

    var pool: std.ArrayList(InodeAndPath) = .initBuffer(&.{.{
        .inode = inode,
        .path = path,
        .root = true,
    }});
    defer {
        while (pool.pop()) |in|
            in.deinit(in);
        pool.deinit(alloc);
    }

    var dirs: std.ArrayList(InodeAndPath) = .empty;
    defer {
        while (dirs.pop()) |dir|
            alloc.free(dir.path);
        dirs.deinit(alloc);
    }

    // TODO: Use options
    _ = options;

    while (pool.pop()) |in| {
        switch (in.inode.data) {
            .dir => |d| {
                try Io.Dir.cwd().createDirPath(io, in.path);

                if (d.size <= 3) {
                    defer if (in.path.len != path.len)
                        in.deinit(alloc);
                    // TODO: apply permissions & xattrs immediately.
                    continue;
                }

                var meta: MetadataReader = .init(alloc, data[d.start], decomp);
                try meta.interface.discardAll(d.offset);

                var dir: Directory = .read(alloc, &meta.interface, d.size);
                defer dir.deinit(alloc);

                for (dir.entries) |entry| {
                    const new_inode: Inode = try .readLocation(alloc, data, entry.start, entry.offset, super);

                    const new_path = std.mem.concat(alloc, u8, &.{ in.path, "/", entry.name }) catch |err| {
                        new_inode.deinit(alloc);
                        return err;
                    };

                    try pool.append(alloc, .{
                        .inode = new_inode,
                        .path = new_path,
                        .root = false,
                    });
                }

                try dirs.append(alloc, in);
            },
            .file => |f| {
                defer if (in.path.len != path.len)
                    in.deinit(alloc);

                var atomic = try Io.Dir.cwd().createFileAtomic(io, in.path, .{});
                defer atomic.deinit(io);

                var rdr: DataReader = .init(alloc, data[f.start..], decomp, super.block_size, f.size, f.blocks);
                defer rdr.deinit();

                if (f.frag_idx != 0xFFFFFFFF) {
                    //TODO: fragment
                }

                var writer = atomic.file.writer(io, &[0]u8{}); // TODO: find a resonable buffer size.
                try rdr.interface.streamRemaining(&writer.interface);

                // TODO: apply permissions & xattrs

                try atomic.link(io);
            },
            .symlink => |s| {
                defer if (in.path.len != path.len)
                    in.deinit(alloc);

                try Io.Dir.cwd().symLink(io, s.target, in.path, .{});
            },
            .dev => |d| {
                defer if (in.path.len != path.len)
                    in.deinit(alloc);

                const mode = switch (in.inode.header.type) {
                    .char_dev, .ext_char_dev => std.os.linux.DT.CHR,
                    .block_dev, .ext_block_dev => std.os.linux.DT.BLK,
                    else => unreachable,
                };

                const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

                const res = std.os.linux.mknod(sent_path, mode, d.device);
                alloc.free(sent_path);
                if (res != 0)
                    return error.MkNodError;

                // TODO: apply permissions & xattrs
            },
            .fifo => |f| {
                _ = f;

                defer if (in.path.len != path.len)
                    in.deinit(alloc);

                const mode = switch (in.inode.header.type) {
                    .fifo, .ext_fifo => std.os.linux.DT.FIFO,
                    .socket, .ext_socket => std.os.linux.DT.SOCK,
                    else => unreachable,
                };

                const sent_path = try alloc.dupeSentinel(u8, in.path, 0);

                const res = std.os.linux.mknod(sent_path, mode, 0);
                alloc.free(sent_path);
                if (res != 0)
                    return error.MkNodError;

                // TODO: apply permissions & xattrs
            },
        }
    }

    while (dirs.pop()) |dir| {
        defer if (dir.path.len != path.len)
            alloc.free(dir.path);
        // TODO: apply permissions & xattrs
    }
}
pub fn multi() !void {}

// Utils

const InodeAndPath = struct {
    inode: Inode,
    path: []const u8,
    root: bool,

    fn deinit(self: InodeAndPath, alloc: std.mem.Allocator) void {
        if (self.root) return;
        self.inode.deinit(alloc);
        alloc.free(self.path);
    }
};

inline fn applyPermissions(alloc: std.mem.Allocator, io: Io, id_table: Table.Lookup(u16), xattr_table: Table.Xattr, inode: Inode, path: []const u8, options: Options) !void {}

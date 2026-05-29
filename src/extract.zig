const std = @import("std");
const Io = std.Io;

const DecompCache = @import("decomp_cache.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const Superblock = @import("archive.zig").Superblock;

pub fn extract(alloc: std.mem.Allocator, io: Io, inode: Inode, cache: *DecompCache, super: Superblock, ext_loc: []const u8, options: ExtractionOptions) !void {
    _ = alloc;
    _ = io;
    _ = inode;
    _ = cache;
    _ = super;
    _ = ext_loc;
    _ = options;
    return error.TODO;
}

pub fn extractDir(alloc: std.mem.Allocator, io: Io, path: []const u8, d: anytype) Error!PathReturn {}
pub fn extractFile(alloc: std.mem.Allocator, io: Io, path: []const u8, d: anytype) Error!PathReturn {
    const atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);

    // TODO

    try atomic.link(io);
    // return .{
    //     .path = path,
    // };
    return error.TODO;
}

// Utility types

const ReturnUnion = union {
    path_ret: Error!PathReturn,
};

const Error = error{};

const PathReturn = struct {
    path: []const u8,

    uid_idx: u32,
    gid_idx: u32,
    mod_time: u32,
    permission: u16,

    xattr_idx: ?u32,
};

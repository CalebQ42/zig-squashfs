//! An easier to use wrapper around an inode.

const std = @import("std");
const Io = std.Io;

const Archive = @import("archive.zig");
const DirEntry = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");

const File = @This();

alloc: std.mem.Allocator,

archive: Archive,

inode: Inode,
name: []const u8,

/// Creates a new File from an inode. Takes ownership of the Inode and creates a copy of the given name.
/// Requires the given allocator was used to create the Inode.
pub fn init(alloc: std.mem.Allocator, archive: Archive, in: Inode, name: []const u8) !File {
    const new_name = try alloc.alloc(u8, name.len);
    @memcpy(new_name, name);
    return .{
        .alloc = alloc,

        .archive = archive,

        .inode = in,
        .name = new_name,
    };
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
    self.inode.deinit(self.alloc);
}

pub fn open(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => {},
        else => return Error.NotDirectory,
    }
    return error.TODO;
}

pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = filepath;
    _ = options;
    return error.TODO;
}

// Types

pub const Error = error{
    NotDirectory,
    NotRegularFile,
    NotSymlink,
    NotDevice,
};

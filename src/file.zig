const std = @import("std");
const Io = std.Io;

const Archive = @import("archive.zig");
const Directory = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");

const SfsFile = @This();

alloc: std.mem.Allocator,
archive: *Archive,

inode: Inode,
name: []const u8,

/// The given allocator must have been used to create the Inode and name.
pub fn init(alloc: std.mem.Allocator, archive: *Archive, inode: Inode, name: []const u8) SfsFile {
    return .{
        .alloc = alloc,
        .archive = archive,

        .inode = inode,
        .name = name,
    };
}
pub fn initDirEntry(alloc: std.mem.Allocator, io: Io, archive: *Archive, entry: Directory.Entry) !SfsFile {
    const new_name = try alloc.alloc(u8, entry.name.len);
    defer alloc.free(new_name);
    @memcpy(new_name, entry.name);

    return .{
        .alloc = alloc,
        .archive = archive,

        .inode = try .initDirEntry(
            alloc,
            io,
            &archive.cache,
            archive.super.inode_start,
            archive.super.block_size,
            entry,
        ),
        .name = new_name,
    };
}
/// Creates a new copy of the given SfsFile using the given allocator
pub fn copy(self: SfsFile, alloc: std.mem.Allocator) !SfsFile {
    const new_name = try alloc(u8, self.name.len);
    errdefer alloc.free(new_name);

    return .{
        .alloc = alloc,
        .archive = self.archive,

        .inode = try self.inode.copy(alloc),
        .name = new_name,
    };
}
pub fn deinit(self: SfsFile) void {
    self.inode.deinit(self.alloc);
    self.alloc.free(self.name);
}

/// Attempts to open the filepath if the SfsFile is a directory.
/// If the given path refers to itself (such as "" or "."), a copied SfsFile is returned.
pub fn open(self: SfsFile, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !SfsFile {
    const path = std.mem.trim(u8, filepath, "/");

    const first_element: []const u8 = std.mem.sliceTo(path, '/');

    const dir: Directory = try self.inode.directory(alloc, io, &self.archive.cache, self.archive.super.dir_start);
    defer dir.deinit(alloc);

    var cur_slice = dir.entries;
    var idx: usize = undefined;
    while (cur_slice.len > 0) {
        idx = cur_slice.len / 2;
        switch (std.mem.order(u8, first_element, cur_slice[idx].name)) {
            .eq => break,
            .lt => cur_slice = cur_slice[0..idx],
            .gt => cur_slice = cur_slice[idx..],
        }
    } else {
        return error.NotFound;
    }
    if (first_element.len == path.len) return .initDirEntry(alloc, io, self.archive, cur_slice[idx]);
    if (cur_slice[idx].type != .dir) return error.NotFound;
    const tmp_file: SfsFile = try .initDirEntry(alloc, io, self.archive, cur_slice[idx]);
    defer tmp_file.deinit();

    return tmp_file.open(alloc, io, path[first_element.len..]);
}

pub fn extract(self: SfsFile, alloc: std.mem.Allocator, io: Io, ext_dir: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = ext_dir;
    _ = options;
    return error.TODO;
}

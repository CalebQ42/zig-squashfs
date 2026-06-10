//! A squashfs file/directory. Basically a wrapper around an Inode.

const std = @import("std");
const Io = std.Io;

const Directory = @import("directory.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("meta_rdr.zig");
const Decomp = @import("decomp.zig");
const Superblock = @import("archive.zig").Superblock;
const ExtractionOptions = @import("options.zig");
const Extract = @import("extract.zig");

const File = @This();

alloc: std.mem.Allocator,

super: Superblock,
data: []u8,
decomp: Decomp.Fn,

name: []const u8,
inode: Inode,

/// The given allocator should have been used to create the name and inode.
pub fn init(alloc: std.mem.Allocator, super: Superblock, data: []u8, decomp: Decomp.Fn, name: []const u8, inode: Inode) File {
    return .{
        .alloc = alloc,

        .super = super,
        .data = data,
        .decomp = decomp,

        .name = name,
        .inode = inode,
    };
}
/// The name from the directory entry will be duplicated so it's safe to deinit the entry.
pub fn initEntry(alloc: std.mem.Allocator, super: Superblock, data: []u8, decomp: Decomp.Fn, entry: Directory.Entry) !File {
    const inode: Inode = try .initEntry(alloc, data, decomp, super.inode_start, super.block_size, entry);
    errdefer inode.deinit(alloc);

    const new_name = try alloc.dupe(entry.name);

    return init(alloc, super, data, decomp, new_name, inode);
}
/// The given name is will be duplicated so it's safe to free it afterwards.
pub fn initRef(alloc: std.mem.Allocator, super: Superblock, data: []u8, decomp: Decomp.Fn, name: []const u8, ref: Inode.Ref) !File {
    const inode: Inode = try .initRef(alloc, data, decomp, super.inode_start, super.block_size, ref);
    errdefer inode.deinit(alloc);

    const new_name = try alloc.dupe(name);

    return init(alloc, super, data, decomp, new_name, inode);
}
pub fn copy(self: File, alloc: std.mem.Allocator) !File {
    const inode = self.inode;
    switch (inode.data) {
        .file => |*f| f.blocks = try alloc.dupe(self.inode.data.file.blocks),
        .ext_file => |*f| f.blocks = try alloc.dupe(self.inode.data.file.blocks),
        .symlink => |*s| s.target = try alloc.dupe(self.inode.data.symlink.target),
        .ext_symlink => |*s| s.target = try alloc.dupe(self.inode.data.symlink.target),
        else => {},
    }
    errdefer inode.deinit(alloc);

    const new_name = try alloc.dupe(self.name);

    return init(alloc, self.super, self.data, self.decomp, new_name, inode);
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
    self.inode.deinit(self.alloc);
}

/// If the given File is a directory, open a sub-file at the given filepath.
/// If the given filepath resolves to the calling File ("" or "."), a copy of the File is returned.
pub fn open(self: File, alloc: std.mem.Allocator, filepath: []const u8) !File {
    var size: u64 = 0;
    var meta: MetadataReader = switch (self.inode.data) {
        .dir => |d| blk: {
            size = d.size;

            var meta: MetadataReader = .init(alloc, self.data, self.decomp, self.super.dir_start + d.block_start);
            try meta.interface.discardAll(d.block_offset);
            break :blk meta;
        },
        .ext_dir => |d| blk: {
            size = d.size;

            var meta: MetadataReader = .init(alloc, self.data, self.decomp, self.super.dir_start + d.block_start);
            try meta.interface.discardAll(d.block_offset);
            break :blk meta;
        },
        else => error.NotDirectory,
    };

    const path = std.mem.trim(u8, filepath, "/");

    if (path.len == 0 or (path.len == 1 and path[0] == '.'))
        return self.copy(alloc);

    const first_element: []u8 = std.mem.sliceTo(path, '/');

    const file: File = blk: {
        var directory: Directory = try .init(alloc, &meta.interface, size);
        defer directory.deinit(alloc);

        var entries = directory.entries;
        var idx = entries.len / 2;

        while (entries.len > 0) {
            switch (std.mem.order(u8, first_element, entries[idx].name)) {
                .eq => break,
                .lt => entries = entries[0..idx],
                .gt => entries = entries[idx..],
            }
            idx = entries.len / 2;
        } else {
            return error.NotFound;
        }

        break :blk try initEntry(alloc, self.super, self.data, self.decomp, entries[idx]);
    };

    if (first_element.len == path.len)
        return file;
    defer file.deinit();

    return file.open(alloc, path[first_element.len..]);
}

pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, location: []const u8, options: ExtractionOptions) !void {
    return Extract.extract(
        alloc,
        io,
        self.super,
        self.data,
        self.decomp,
        self.inode,
        location,
        options,
    );
}

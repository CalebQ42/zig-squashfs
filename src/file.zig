const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");
const Directory = @import("dir.zig");
const MetadataReader = @import("utils/meta.zig");
const Options = @import("options.zig");
const DataReader = @import("utils/data_reader.zig");
const Decompress = @import("utils/decompress.zig");
const Super = @import("archive.zig").Super;

const File = @This();

alloc: std.mem.Allocator,

data: []u8,
super: Super,

name: []const u8,
inode: Inode,

pub fn copy(self: File, alloc: std.mem.Allocator) !File {
    const new_name = try alloc.dupe(u8, self.name);
    errdefer alloc.free(new_name);

    return .{
        .alloc = alloc,

        .data = self.data,
        .super = self.super,

        .name = new_name,
        .inode = try self.inode.copy(alloc),
    };
}
pub fn deinit(self: File) void {
    self.inode.deinit(self.alloc);
    self.alloc.free(self.name);
}

/// Reader interface to read a regular file's contents.
pub fn reader(self: File, alloc: std.mem.Allocator) !DataReader {
    return switch (self.inode.header.type) {
        .file => |f| .init(
            alloc,
            self.data,
            self.super.decomp_fn,
            self.super.block_size,
            f.start,
            f.size,
            f.blocks,
        ),
        .ext_file => |f| .init(
            alloc,
            self.data,
            self.super.decomp_fn,
            self.super.block_size,
            f.start,
            f.size,
            f.blocks,
        ),
        else => error.NotRegularFile,
    };
}

pub fn open(self: File, alloc: std.mem.Allocator, filepath: []const u8) !File {
    switch (self.inode.header.type) {
        .dir, .ext_dir => {},
        else => return error.NotDirectory,
    }

    const path = std.mem.trim(u8, filepath, "/");

    if (path.len == 0 or (path.len == 1 and path[0] == '.'))
        return self.copy(alloc);

    const first_element: []const u8 = std.mem.sliceTo(path, '/');
    const final = first_element.len == path.len;

    var dir_rdr: MetadataReader = .init(alloc, self.data[self.inode.data.dir.start + self.super.dir_table_start ..], self.super.decomp_fn);
    try dir_rdr.interface.discardAll(self.inode.data.dir.offset);

    const dir_size = self.inode.data.dir.size;

    const entry: Directory.Entry = blk: {
        var dir: Directory = try .read(alloc, &dir_rdr.interface, dir_size);
        defer dir.deinit(alloc);

        var entries = dir.entries;
        var idx: usize = undefined;

        while (entries.len > 1) {
            idx = entries.len / 2;
            const val = entries[idx];

            switch (std.mem.order(u8, first_element, val.name)) {
                .eq => break,
                .lt => entries = entries[0..idx],
                .gt => entries = entries[idx..],
            }
        } else {
            if (!std.mem.eql(u8, first_element, entries[0].name))
                return error.NotFound;
            idx = 0;
        }

        if (!final) break :blk entries[idx];

        const inode: Inode = try .readLocation(
            alloc,
            self.data,
            entries[idx].start,
            entries[idx].offset,
            self.super,
        );
        errdefer inode.deinit(alloc);

        return .{
            .alloc = alloc,

            .data = self.data,
            .super = self.super,

            .inode = inode,
            .name = try alloc.dupe(u8, entries[idx].name),
        };
    };

    if (entry.type != .dir)
        return error.NotFound;

    const transient_file: File = .{
        .alloc = alloc,

        .data = self.data,
        .super = self.super,

        .inode = try .readLocation(
            alloc,
            self.data,
            entry.start,
            entry.offset,
            self.super,
        ),
        .name = "",
    }; // We don't care about deiniting this file since dir inodes don't need to be deinited and we don't have an allocd name.

    return transient_file.open(alloc, path[first_element.len + 1 ..]);
}

/// Extract the given File to the location.
pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: Options) !void {
    // TODO: do some basic processing to check if ext_loc is a folder & if self is regular file and adjust accordingly.

    if (options.single_threaded)
        return Decompress.single(alloc, io, self.map.memory, self.super, self.inode, ext_loc, options);
    return Decompress.multi(alloc, io, self.map.memory, self.super, self.inode, ext_loc, options);
}

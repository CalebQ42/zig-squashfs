const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");
const Directory = @import("dir.zig");
const MetadataReader = @import("utils/meta.zig");
const Options = @import("options.zig");
const DataReader = @import("utils/data_reader.zig");
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

        while (entries.len > 1) {
            const idx = entries.len / 2;
            const val = entries[idx];

            switch (std.mem.order(u8, first_element, val.name)) {
                .eq => {
                    if (final) {
                        const inode: Inode = try .readLocation(
                            alloc,
                            self.data,
                            val.start,
                            val.offset,
                            self.super,
                        );
                        errdefer inode.deinit(alloc);

                        return .{
                            .alloc = alloc,

                            .data = self.data,
                            .super = self.super,

                            .inode = inode,
                            .name = try alloc.dupe(u8, val.name),
                        };
                    }
                    break :blk val;
                },
                .lt => entries = entries[0..idx],
                .gt => entries = entries[idx..],
            }
        }
        return error.NotFound;
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
    };

    return transient_file.open(alloc, filepath[first_element.len..]);
}

/// Extract the given File to the location.
pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: Options) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = ext_loc;
    _ = options;
    return error.TODO;
}

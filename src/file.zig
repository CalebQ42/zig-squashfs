const std = @import("std");
const Io = std.Io;

const Inode = @import("inode.zig");
const DirIter = @import("dir.zig");
const MetadataReader = @import("utils/meta.zig");
const Options = @import("options.zig");
const DataReader = @import("utils/data_reader.zig");
const Super = @import("archive.zig").Super;
const Decomp = @import("decomp.zig");

const extractFn = @import("extract.zig").extract;

const File = @This();

alloc: std.mem.Allocator,

data: []u8,
super: Super,
decomp: *Decomp,

name: []const u8,
inode: Inode,

pub fn init(alloc: std.mem.Allocator, data: []u8, super: Super, decomp: *Decomp, inode: Inode, name: []u8) !File {
    const new_name = try alloc.dupe(u8, name);
    errdefer alloc.free(new_name);

    return .{
        .alloc = alloc,

        .data = data,
        .super = super,
        .decomp = decomp,

        .name = new_name,
        .inode = try inode.copy(alloc),
    };
}
pub fn copy(self: File, alloc: std.mem.Allocator) !File {
    const new_name = try alloc.dupe(u8, self.name);
    errdefer alloc.free(new_name);

    return .{
        .alloc = alloc,

        .data = self.data,
        .super = self.super,
        .decomp = self.decomp,

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
    return switch (self.inode.data) {
        .file => |f| .init(
            alloc,
            self.data,
            self.decomp,
            self.super.block_size,
            f.start,
            f.size,
            f.blocks,
        ),
        else => error.NotRegularFile,
    };
}

pub fn open(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    switch (self.inode.header.type) {
        .dir, .ext_dir => {},
        else => return error.NotDirectory,
    }

    var path = std.mem.trim(u8, filepath, "/");

    if (path.len == 0 or (path.len == 1 and path[0] == '.'))
        return self.copy(alloc);

    var dir = self.inode.data.dir;

    while (path.len > 0) {
        if (dir.size <= 3)
            return error.NotFound;

        const first_element: []const u8 = std.mem.sliceTo(path, '/');
        const final = first_element.len == path.len;

        var dir_rdr: MetadataReader = .init(io, self.data[dir.start + self.super.dir_table_start ..], self.decomp);
        try dir_rdr.interface.discardAll(dir.offset);

        var name_buf: [100]u8 = undefined;

        var iter: DirIter = .init(alloc, &dir_rdr.interface, &name_buf, dir.size);

        while (try iter.next()) |entry| {
            defer if (entry.name.len > name_buf.len)
                alloc.free(entry.name);

            switch (std.mem.order(u8, first_element, entry.name)) {
                .lt => return error.NotFound,
                .gt => continue,
                else => {},
            }

            if (!final and entry.type != .dir) return error.NotFound;

            const inode: Inode = try .readLocation(alloc, io, self.data, self.super, self.decomp, iter.hdr.start, entry.offset);
            defer inode.deinit(alloc);

            if (final)
                return .init(alloc, self.data, self.super, self.decomp, inode, entry.name);

            dir = inode.data.dir;
            path = path[first_element.len + 1 ..];
            break;
        } else return error.NotFound;
    }
    return error.NotFound;
}

/// Extract the given File to the location.
pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: Options) !void {
    const stat = Io.Dir.cwd().statFile(io, ext_loc, .{}) catch |err| switch (err) {
        error.FileNotFound => return extractFn(alloc, io, self.data, self.super, self.decomp, self.inode, ext_loc, options),
        else => return err,
    };
    if ((self.inode.header.type == .dir or self.inode.header.type == .ext_dir) and stat.kind == .directory)
        return extractFn(alloc, io, self.data, self.super, self.decomp, self.inode, ext_loc, options);

    if (stat.kind == .directory) {
        const new_loc = try std.mem.concat(alloc, u8, &.{ std.mem.trim(u8, ext_loc, "/"), "/", self.name });
        defer alloc.free(new_loc);

        return extractFn(alloc, io, self.data, self.super, self.decomp, self.inode, new_loc, options);
    } else if (!options.overwrite) return error.FileExists;
}

//! A wrapper around an Inode to make common activities easier.

const std = @import("std");
const Io = std.Io;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const LookupTable = @import("lookup_table.zig");
const MetadataReader = @import("util/metadata.zig");

pub const Error = error{
    NotFound,
};

const File = @This();

alloc: std.mem.Allocator,
archive: *Archive,

name: []const u8,
inode: Inode,

pub fn fromEntry(alloc: std.mem.Allocator, io: Io, archive: *Archive, entry: DirEntry) !File {
    var meta: MetadataReader = .init(io, &archive.cache, archive.super.inode_start + entry.block_start);
    defer meta.deinit();
    try meta.interface.discardAll(entry.block_offset);

    const new_name = try alloc.alloc(u8, entry.name.len);
    errdefer alloc.free(new_name);
    @memcpy(new_name, entry.name);

    return .{
        .alloc = alloc,
        .archive = archive,

        .name = new_name,
        .inode = try .fromReader(alloc, &meta.interface, archive.super.block_size),
    };
}
/// Create a File from an Inode.Ref. name should be created using the alloc given.
pub fn fromRef(alloc: std.mem.Allocator, io: Io, archive: *Archive, name: []const u8, ref: Inode.Ref) !File {
    return .{
        .alloc = alloc,
        .archive = archive,

        .name = name,
        .inode = try .fromRef(
            alloc,
            io,
            &archive.cache,
            archive.super.inode_start,
            archive.super.block_size,
            ref,
        ),
    };
}
pub fn copy(alloc: std.mem.Allocator, from: File) !File {
    const new_name = try alloc.alloc(u8, from.name.len);
    errdefer alloc.free(new_name);
    @memcpy(new_name, from.name);

    return .{
        .alloc = alloc,
        .archive = from.archive,

        .inode = try .copy(alloc, from.inode),
        .name = new_name,
    };
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
    self.inode.deinit(self.alloc);
}

pub fn open(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    const path = std.mem.trim(u8, filepath, "/");

    if (path.len == 0 or std.mem.eql(u8, path, ".")) return .copy(alloc, self);

    const first_element = std.mem.sliceTo(path, '/');

    const entries = try self.inode.readDirectory(alloc, io, &self.archive.cache, self.archive.super.dir_start);
    defer {
        for (entries) |entry|
            entry.deinit(alloc);
        alloc.free(entries);
    }

    // Potentially I could use linear searching on small dir tables...
    var search_slice = entries;
    var idx = search_slice.len / 2;
    while (search_slice.len > 0) {
        const order = std.mem.order(u8, first_element, search_slice[idx].name);
        switch (order) {
            .eq => break,
            .gt => search_slice = search_slice[idx..],
            .lt => search_slice = search_slice[0..idx],
        }
        idx = search_slice.len / 2;
    }
    if (search_slice.len == 0) return Error.NotFound;

    var fil: File = try .fromEntry(alloc, io, self.archive, search_slice[idx]);
    if (path.len == first_element.len) return fil;
    defer fil.deinit();

    return fil.open(alloc, io, filepath[first_element.len..]);
}

pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, path: []const u8, options: ExtractionOptions) !void {
    return self.inode.extract(
        alloc,
        io,
        &self.archive.cache,
        self.archive.super.dir_start,
        self.archive.super.inode_start,
        self.archive.super.frag_start,
        self.archive.super.block_size,
        self.archive.super.id_start,
        self.archive.super.xattr_start,
        path,
        options,
    );
}

//! An easier to use wrapper around an inode.

const std = @import("std");
const Io = std.Io;

const Archive = @import("archive.zig");
const DirEntry = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const DataExtractor = @import("util/data_extractor.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const SharedCache = @import("util/shared_cache.zig");

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
pub fn fromDirEntry(alloc: std.mem.Allocator, archive: Archive, ent: DirEntry) !File {
    var rdr = archive.file.readerAt(archive.super.inode_start + ent.block_start);
    var meta: MetadataReader = .init(alloc, &rdr, archive.stateless_decomp);
    try meta.interface.discardAll(ent.block_offset);

    var in: Inode = try .read(alloc, &meta.interface, archive.super.block_size);
    errdefer in.deinit(alloc);
    return .init(alloc, archive, in, ent.name);
}
pub fn deinit(self: File) void {
    self.alloc.free(self.name);
    self.inode.deinit(self.alloc);
}

pub fn open(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    const entries = try self.inode.readDirectory(
        alloc,
        self.archive.file,
        self.archive.stateless_decomp,
        self.archive.super.dir_start,
    );
    defer {
        for (entries) |ent|
            alloc.free(ent.name);
        alloc.free(entries);
    }
    const path = std.mem.trim(u8, filepath, "/");
    const first_element: []const u8 = std.mem.sliceTo(path, '/');

    var search_slice = entries;
    var idx: usize = undefined;
    while (search_slice.len > 0) {
        idx = search_slice.len / 2;
        const middle = search_slice[idx];
        switch (std.mem.order(u8, first_element, middle.name)) {
            .eq => break,
            .lt => search_slice = search_slice[0..idx],
            .gt => search_slice = search_slice[idx + 1 ..],
        }
    } else return Error.FileNotFound;

    const first_elem_file = try fromDirEntry(alloc, self.archive, search_slice[idx]);
    if (first_element.len == path.len)
        return first_elem_file;
    defer first_elem_file.deinit();
    return first_elem_file.open(alloc, io, path[first_element.len + 1 ..]);
}

pub fn extract(self: File, alloc: std.mem.Allocator, io: Io, filepath: []const u8, options: ExtractionOptions) !void {
    return self.inode.extract(alloc, io, self.archive.file, self.archive.super, filepath, options);
}

// Types

pub const Error = error{
    FileNotFound,
} || Inode.Error;

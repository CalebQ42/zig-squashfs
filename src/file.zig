const std = @import("std");
const Io = std.Io;

const Archive = @import("archive.zig");
const Decompressor = @import("decomp.zig");
const Directory = @import("directory.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const DataReader = @import("util/data_reader.zig");
const FileIter = @import("util/iter.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const Utils = @import("util/utils.zig");

pub const Error = error{
    NotDirectory,
    NotRegularFile,
};

const File = @This();

file: OffsetFile,
super: Archive.MinimalSuperblock,
decomp: Decompressor,

name: []const u8,
inode: Inode,

pub fn init(alloc: std.mem.Allocator, archive: Archive, entry: Directory.Entry) !File {
    const new_name = try alloc.alloc(u8, entry.name.len);
    errdefer alloc.free(new_name);
    @memcpy(new_name, entry.name);
    return .{
        .file = archive.file,
        .super = archive.super,
        .decomp = archive.stateless_decomp.statelessCopy(alloc),
        .name = new_name,
        .inode = try Utils.readInode(
            alloc,
            &archive.decomp,
            archive.file,
            archive.super.inode_start,
            archive.super.block_size,
            entry.block_start,
            entry.block_offset,
        ),
    };
}
pub fn deinit(self: File) void {
    self.decomp.alloc.free(self.name);
    self.inode.deinit(self.decomp.alloc);
}

// Directory functions

pub fn isDir(self: File) bool {
    return switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => true,
        else => false,
    };
}
/// Opens a sub-file. If the given path is "" or "." (after trimming /) a copy of the File is returned.
pub fn open(self: File, alloc: std.mem.Allocator, filepath: []const u8) !File {
    var res = try self.inode.findInode(
        alloc,
        &self.decomp,
        self.file,
        self.super.dir_start,
        self.super.inode_start,
        self.super.block_size,
        filepath,
    );
    if (res.name.len == 0) {
        res.name = try alloc.alloc(u8, self.name.len);
        @memcpy(res.name, self.name);
    }
    return .{
        .file = self.file,
        .super = self.super,
        .decomp = self.decomp.statelessCopy(alloc),
        .name = res.name,
        .inode = res.inode,
    };
}
pub fn iter(self: File, alloc: std.mem.Allocator) !FileIter {
    return .{
        .alloc = alloc,
        .entries = try self.inode.readDirectory(alloc, &self.decomp, self.file, self.super.dir_start),
    };
}

// Regular file functions

pub fn isRegularFile(self: File) bool {
    return switch (self.inode.hdr.inode_type) {
        .file, .ext_file => true,
        else => false,
    };
}
// a std.Io.Reader compatible reader that reads a regular file's data.
pub fn dataReader(self: File, alloc: std.mem.Allocator) !DataReader {
    return self.inode.dataReader(
        &self.decomp.statelessCopy(alloc),
        self.file,
        self.super.frag_start,
        self.super.block_size,
    );
}

// Universal functions

pub fn extract(self: File, alloc: std.mem.Allocator, path: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = path;
    _ = options;
    return error.TODO;
}

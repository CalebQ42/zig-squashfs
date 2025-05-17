const std = @import("std");
const io = std.io;

const inode = @import("inode/inode.zig");
const directory = @import("directory.zig");

const Reader = @import("reader.zig").Reader;
const DirEntry = @import("directory.zig").DirEntry;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const FileError = error{
    NotDirectory,
    NotNormalFile,
    NotSymlink,
    NotFound,
};

pub const File = struct {
    name: []const u8,
    inode: inode.Inode,
    dirEntries: std.StringHashMap(DirEntry) = undefined,
    hasEntries: bool = false,

    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        self.inode.deinit();
        alloc.free(self.name);
        if (self.hasEntries) {
            var iter = self.dirEntries.iterator();
            while (iter.next()) |ent| {
                ent.value_ptr.deinit(alloc);
            }
            self.dirEntries.deinit();
        }
    }

    pub fn open(self: *File, reader: *Reader, path: []const u8) !File {
        return self.realOpen(reader, path, true);
    }

    fn realOpen(self: *File, reader: *Reader, path: []const u8, first: bool) !File {
        const clean_path: []const u8 = std.mem.trimLeft(u8, path, "/");
        if (clean_path.len == 0) {
            return self.*;
        }
        if (!first) {
            defer reader.alloc.free(path);
            defer self.deinit(reader.alloc);
        }
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {},
            else => return FileError.NotDirectory,
        }
        if (!self.hasEntries) {
            try self.readDirEntries(reader);
        }
        const split_idx = std.mem.indexOf(u8, clean_path, "/") orelse clean_path.len;
        const name = clean_path[0..split_idx];
        const ent = self.dirEntries.get(name);
        if (ent == null) {
            return FileError.NotFound;
        }
        var fil = try fileFromDirEntry(reader, ent.?);
        return fil.realOpen(reader, clean_path[split_idx..], false);
    }

    pub fn symPath(self: File) ![]const u8 {
        return switch (self.inode.data) {
            .sym => |s| s.target,
            .ext_sym => |s| s.target,
            else => FileError.NotSymlink,
        };
    }

    fn readDirEntries(self: *File, reader: *Reader) !void {
        var block_start: u32 = 0;
        var offset: u16 = 0;
        var size: u32 = 0;
        switch (self.inode.data) {
            .dir => |d| {
                block_start = d.block_start;
                offset = d.offset;
                size = d.size;
            },
            .ext_dir => |d| {
                block_start = d.block_start;
                offset = d.offset;
                size = d.size;
            },
            else => return FileError.NotDirectory,
        }
        var offset_rdr = reader.holder.readerAt(reader.super.dir_table_start + block_start);
        var meta_rdr: MetadataReader = try .init(
            reader.alloc,
            offset_rdr.any(),
            reader.super.decomp,
        );
        defer meta_rdr.deinit();
        self.dirEntries = try directory.readDirectory(reader.alloc, meta_rdr.any(), size);
        self.hasEntries = true;
    }
};

fn fileFromDirEntry(read: *Reader, ent: DirEntry) !File {
    var offset_rdr = read.holder.readerAt(ent.block_start + read.super.inode_table_start);
    var meta_rdr: MetadataReader = try .init(
        read.alloc,
        offset_rdr.any(),
        read.super.decomp,
    );
    defer meta_rdr.deinit();
    try meta_rdr.skip(ent.offset);
    return .{
        .name = ent.name,
        .inode = try .init(
            read.alloc,
            meta_rdr.any(),
            read.super.block_size,
        ),
    };
}

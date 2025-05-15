const std = @import("std");

const inode = @import("inode.zig");
const Reader = @import("squashfs.zig").Reader;
const MetadataReader = @import("metadata_reader.zig").MetadataReader;
const FileOffsetReader = @import("file_offset_reader.zig").FileOffsetReader;
const dir = @import("directory.zig");

const FileOpenError = error{
    NotFound,
    NotDirectory,
};

pub const File = struct {
    rdr: *Reader,
    inode: inode.Inode,
    name: []const u8,
    dir_entries: []dir.DirEntry = &[0]dir.DirEntry{},

    pub fn fromRef(rdr: *Reader, ref: inode.InodeRef, name: []const u8) !File {
        var offset_rdr: FileOffsetReader = .init(rdr.rdr, rdr.super.inode_table + ref.block_start);
        var meta_rdr: MetadataReader = .init(rdr.super.comp, offset_rdr.any(), rdr.alloc.allocator());
        try meta_rdr.skip(ref.offset);
        const in = try inode.readInode(meta_rdr, rdr.super.block_size, rdr.alloc.allocator());
        return .{
            .rdr = rdr,
            .inode = in,
            .name = name,
        };
    }

    pub fn fromDirEntry(rdr: *Reader, ent: dir.DirEntry) !File {
        var offset_rdr: FileOffsetReader = .init(&rdr.rdr, rdr.super.inode_table + ent.inode_block_start);
        var meta_rdr: MetadataReader = try .init(
            rdr.super.comp,
            offset_rdr.any(),
            rdr.alloc.allocator(),
        );
        try meta_rdr.skip(ent.inode_offset);
        const in = try inode.readInode(meta_rdr.any(), rdr.super.block_size, rdr.alloc.allocator());
        return .{
            .rdr = rdr,
            .inode = in,
            .name = ent.name,
        };
    }

    pub fn open(self: *File, path: []const u8) (anyerror || FileOpenError)!File {
        if (path.len == 0) return self.*;
        const clean_path: []const u8 = std.mem.trimLeft(u8, path, "/");
        if (clean_path.len == 0 or std.mem.eql(u8, clean_path, ".")) {
            return self.*;
        }
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {},
            else => return FileOpenError.NotDirectory,
        }
        try self.readDirEntries();
        const file_name = std.mem.sliceTo(clean_path, '/');
        for (self.dir_entries) |ent| {
            std.debug.print("yo {}\n", .{ent});
            if (std.mem.eql(u8, file_name, ent.name)) {
                return try File.fromDirEntry(self.rdr, ent);
            }
        }
        return FileOpenError.NotFound;
    }

    fn readDirEntries(self: *File) (anyerror || FileOpenError)!void {
        if (self.dir_entries.len != 0) {
            return;
        }
        var dir_block_offset: u32 = undefined;
        var dir_block_start: u32 = undefined;
        var size: u32 = undefined;
        switch (self.inode.data) {
            .dir => |d| {
                dir_block_start = d.dir_block_start;
                dir_block_offset = d.dir_block_offset;
                size = d.dir_table_size;
            },
            .ext_dir => |d| {
                dir_block_start = d.dir_block_start;
                dir_block_offset = d.dir_block_offset;
                size = d.dir_table_size;
            },
            else => return FileOpenError.NotDirectory,
        }
        std.debug.print("{}\n", .{self.rdr});
        var offset_rdr: FileOffsetReader = .init(&self.rdr.rdr, self.rdr.super.dir_table + dir_block_start);
        var meta_rdr: MetadataReader = try .init(self.rdr.super.comp, offset_rdr.any(), self.rdr.alloc.allocator());
        self.dir_entries = try dir.readDirEntries(self.rdr.alloc.allocator(), self.rdr.super.comp, meta_rdr.any(), size);
    }
};

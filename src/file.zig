const std = @import("std");
const io = std.io;
const fs = std.fs;

const inode = @import("inode/inode.zig");
const directory = @import("directory.zig");
const data = @import("readers/data.zig");

const Reader = @import("reader.zig").Reader;
const DirEntry = @import("directory.zig").DirEntry;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

/// A file or directory inside of a squashfs.
/// Make sure to call deinit();
pub const File = struct {
    name: []const u8,
    inode: inode.Inode,
    dirEntries: ?std.StringHashMap(DirEntry) = null,

    data_rdr: ?data.DataReader = null,

    pub const FileError = error{
        NotDirectory,
        NotNormalFile,
        NotSymlink,
        NotFound,
    };

    fn fromDirEntry(rdr: *Reader, ent: DirEntry) !File {
        var offset_rdr = rdr.holder.readerAt(ent.block_start + rdr.super.inode_table_start);
        var meta_rdr: MetadataReader = .init(
            rdr.alloc,
            rdr.super.decomp,
            offset_rdr.any(),
        );
        defer meta_rdr.deinit();
        try meta_rdr.skip(ent.offset);
        const out: File = .{
            .name = try rdr.alloc.alloc(u8, ent.name.len),
            .inode = try .init(
                rdr.alloc,
                meta_rdr.any(),
                rdr.super.block_size,
            ),
        };
        std.mem.copyForwards(u8, @constCast(out.name), ent.name);
        return out;
    }

    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        self.inode.deinit();
        alloc.free(self.name);
        if (self.dirEntries != null) {
            var iter = self.dirEntries.?.iterator();
            while (iter.next()) |ent| {
                ent.value_ptr.deinit(alloc);
            }
            self.dirEntries.?.deinit();
        }
    }

    pub fn isDir(self: File) bool {
        return switch (self.inode.header.inode_type) {
            .dir, .ext_dir => true,
            else => false,
        };
    }

    /// If the File is a directory, tries to return the file at path.
    /// An empty path returns itself.
    pub fn open(self: *File, rdr: *Reader, path: []const u8) !File {
        return self.realOpen(rdr, path, true);
    }

    fn realOpen(self: *File, rdr: *Reader, path: []const u8, first: bool) !File {
        const clean_path: []const u8 = std.mem.trim(u8, path, "/");
        if (clean_path.len == 0) {
            return self.*;
        }
        defer if (!first) self.deinit(rdr.alloc);
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {},
            else => return FileError.NotDirectory,
        }
        try self.readDirEntries(rdr);
        const split_idx = std.mem.indexOf(u8, clean_path, "/") orelse clean_path.len;
        const name = clean_path[0..split_idx];
        const ent = self.dirEntries.?.get(name);
        if (ent == null) {
            return FileError.NotFound;
        }
        var fil = try fromDirEntry(rdr, ent.?);
        return fil.realOpen(rdr, clean_path[split_idx..], false);
    }

    /// If the File is a symlink, returns the symlink's target path.
    pub fn symPath(self: File) ![]const u8 {
        return switch (self.inode.data) {
            .sym => |s| s.target,
            .ext_sym => |s| s.target,
            else => FileError.NotSymlink,
        };
    }

    /// If the File is a directory, returns an iterator that iterates over it's children.
    pub fn iterator(self: *File, rdr: *Reader) !FileIterator {
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {},
            else => return FileError.NotDirectory,
        }
        try self.readDirEntries(rdr);
        var files = try rdr.alloc.alloc(File, self.dirEntries.?.count());
        var dirEntryIter = self.dirEntries.?.valueIterator();
        var i: u32 = 0;
        while (dirEntryIter.next()) |ent| : (i += 1) {
            files[i] = try .fromDirEntry(rdr, ent.*);
        }
        return .{
            .alloc = rdr.alloc,
            .files = files,
        };
    }

    fn readDirEntries(self: *File, rdr: *Reader) !void {
        if (self.dirEntries != null) return;
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
        var offset_rdr = rdr.holder.readerAt(rdr.super.dir_table_start + block_start);
        var meta_rdr: MetadataReader = .init(
            rdr.alloc,
            rdr.super.decomp,
            offset_rdr.any(),
        );
        defer meta_rdr.deinit();
        try meta_rdr.skip(offset);
        self.dirEntries = try directory.readDirectory(rdr.alloc, meta_rdr.any(), size);
    }

    /// If the file is a normal file, reads it's data.
    pub fn read(self: *File, bytes: []u8) !usize {
        if (self.data_rdr == null) {
            return FileError.NotNormalFile;
        }
        return self.data_rdr.?.read(bytes);
    }

    pub const FileReader = io.GenericReader(*File, anyerror, read);

    pub fn reader(self: *File) FileReader {
        return .{
            .context = self,
        };
    }

    /// Extract's the File to the path.
    // pub fn extract(self: *File, rdr: *Reader, path: []const u8) !void {
    //     return self.extractReal(rdr, path, true);
    // }

    // pub fn extractReal(self: *File, rdr: *Reader, path: []const u8, first: bool) !void {
    //     var real_path = try rdr.alloc.alloc(u8, path.len);
    //     @memcpy(real_path, path);
    //     defer rdr.alloc.free(real_path);
    //     real_path = std.mem.trimRight(u8, real_path, "/");
    //     switch (self.inode.header.inode_type) {
    //         .dir, .ext_dir => {},
    //         .file, .ext_file => {
    //             if(first){
    //                 const stat = try fs.cwd().statFile(path);
    //                 fs.File.Kind.unknown
    //                 switch(stat.kind){
    //                     .file => {},
    //                     .directory => {
    //                         if(!rdr.alloc.resize(real_path, real_path.len + self.name.len+1)){
    //                             const len = real_path.len + self.name.len+1;
    //                             rdr.alloc.free(real_path);
    //                             real_path = try rdr.alloc.alloc(u8, len)
    //                         }
    //                     },
    //                     else => error{InvalidPath}.InvalidPath,
    //                 }
    //             }
    //         },
    //         .sym, .ext_sym => {},
    //         .block, .ext_block, .char, .ext_char => {},
    //     }
    // }
};

const FileIterator = struct {
    alloc: std.mem.Allocator,
    files: []File,

    curIndex: u32 = 0,

    pub fn next(self: *FileIterator) ?File {
        if (self.curIndex >= self.files.len) return null;
        defer self.curIndex += 1;
        return self.files[self.curIndex];
    }
    pub fn reset(self: *FileIterator) void {
        self.curIndex = 0;
    }
    pub fn deinit(self: *FileIterator) void {
        for (self.files) |*f| {
            f.deinit(self.alloc);
        }
        self.alloc.free(self.files);
    }
};

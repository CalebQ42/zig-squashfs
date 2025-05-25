const std = @import("std");
const io = std.io;
const fs = std.fs;
const builtin = @import("builtin");

const inode = @import("inode/inode.zig");
const directory = @import("directory.zig");

const Reader = @import("reader.zig").Reader;
const DirEntry = @import("directory.zig").DirEntry;
const DataReader = @import("readers/data_reader.zig").DataReader;
const DataExtractor = @import("readers/data_extractor.zig").DataExtractor;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

/// A file or directory inside of a squashfs.
/// Make sure to call deinit();
pub const File = struct {
    name: []const u8,
    inode: inode.Inode,
    dirEntries: ?std.StringHashMap(DirEntry) = null,

    data_rdr: ?DataReader = null,

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
        const name = try rdr.alloc.alloc(u8, ent.name.len);
        errdefer rdr.alloc.free(name);
        @memcpy(name, ent.name);
        return .{
            .name = name,
            .inode = try .init(
                rdr.alloc,
                meta_rdr.any(),
                rdr.super.block_size,
            ),
        };
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

    fn realOpen(self: *File, rdr: *Reader, path: []const u8, first: bool) (FileError || anyerror)!File {
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
    pub fn symPath(self: File) (FileError || anyerror)![]const u8 {
        return switch (self.inode.data) {
            .sym => |s| s.target,
            .ext_sym => |s| s.target,
            else => FileError.NotSymlink,
        };
    }

    /// If the File is a directory, returns an iterator that iterates over it's children.
    pub fn iterator(self: *File, rdr: *Reader) (FileError || anyerror)!FileIterator {
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

    fn readDirEntries(self: *File, rdr: *Reader) (FileError || anyerror)!void {
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
    pub fn read(self: *File, bytes: []u8) (FileError || anyerror)!usize {
        if (self.data_rdr == null) {
            return FileError.NotNormalFile;
        }
        return self.data_rdr.?.read(bytes);
    }

    const FileReader = io.GenericReader(*File, (FileError || anyerror), read);

    pub fn reader(self: *File) FileReader {
        return .{
            .context = self,
        };
    }

    /// Returns a struct meant to read the file's complete data at once.
    pub fn extractor(self: *File, rdr: *Reader) !DataExtractor {
        return .init(self, rdr);
    }

    pub const ExtractError = error{
        FileExists,
    };

    /// Extract's the File to the path.
    pub fn extract(self: *File, rdr: *Reader, path: []const u8) (ExtractError || anyerror)!void {
        return self.extractReal(rdr, path, true);
    }

    pub fn extractReal(self: *File, rdr: *Reader, path: []const u8, first: bool) (ExtractError || anyerror)!void {
        const real_path = std.mem.trimRight(u8, path, "/");
        var exists = true;
        var stat: ?fs.File.Stat = null;
        if (fs.cwd().statFile(real_path)) |s| {
            stat = s;
        } else |err| {
            if (err == fs.File.OpenError.FileNotFound) {
                exists = false;
            } else return err;
        }
        switch (self.inode.header.inode_type) {
            .dir, .ext_dir => {
                if (!exists) {
                    try fs.cwd().makeDir(real_path);
                }
                var iter = try self.iterator(rdr);
                defer iter.deinit();
                while (iter.next()) |*f| {
                    const extr_path = try std.mem.concat(rdr.alloc, u8, &[3][]const u8{ real_path, "/", f.name });
                    defer rdr.alloc.free(extr_path);
                    try @constCast(f).extractReal(rdr, extr_path, false);
                }
            },
            .file, .ext_file => {
                if ((!first and exists) or
                    (first and exists and stat.?.kind != .directory)) return ExtractError.FileExists;
                const extr_path = if (first and exists and stat.?.kind == .directory) blk: {
                    break :blk try std.mem.concat(rdr.alloc, u8, &[3][]const u8{ real_path, "/", self.name });
                } else blk: {
                    const tmp = try rdr.alloc.alloc(u8, real_path.len);
                    @memcpy(tmp, real_path);
                    break :blk tmp;
                };
                defer rdr.alloc.free(extr_path);
                var ext = try self.extractor(rdr);
                defer ext.deinit();
                const fil = try fs.cwd().createFile(extr_path, .{});
                defer fil.close();
                try ext.writeToFile(try .init(), &fil);
            },
            .sym, .ext_sym => {
                if (exists) return ExtractError.FileExists;
                try fs.cwd().symLink(try self.symPath(), real_path, .{});
            },
            .block, .ext_block, .char, .ext_char, .fifo, .ext_fifo => {
                if (exists) return ExtractError.FileExists;
                comptime if (builtin.os.tag != .linux) return;
                const IFCHR: u32 = 0o020000;
                const IFBLK: u32 = 0o060000;
                const IFIFO: u32 = 0o010000;
                const mode = switch (self.inode.header.inode_type) {
                    .block, .ext_block => IFBLK,
                    .char, .ext_char => IFCHR,
                    .fifo, .ext_fifo => IFIFO,
                    else => unreachable,
                };
                const dev = switch (self.inode.data) {
                    .block, .char => |b| b.device,
                    .ext_block, .ext_char => |b| b.device,
                    .fifo, .ext_fifo => 0,
                    else => unreachable,
                };
                _ = std.os.linux.mknod(@ptrCast(real_path), mode, dev);
            },
            .sock, .ext_sock => {},
        }
        //TODO: permissions
    }
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

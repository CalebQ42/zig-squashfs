//! A file/directory within the squashfs archive.

const std = @import("std");
const File = std.fs.File;
const WaitGroup = std.Thread.WaitGroup;
const Mutex = std.Thread.Mutex;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const BlockSize = @import("inode_data/file.zig").BlockSize;
const DataReader = @import("util/data.zig");
const MetadataReader = @import("util/metadata.zig");

const FileError = error{
    NotDirectory,
    NotRegularFile,
    NotSymlink,
    NotDevice,
    NotFound,
    ExtractionPathExists,
};

const SfsFile = @This();

archive: *Archive,

inode: Inode,
name: []const u8,

/// Initialize a new File.
/// name is copied to the File so can be safely freed afterwards.
pub fn init(archive: *Archive, inode: Inode, name: []const u8) !SfsFile {
    const new_name = try archive.allocator().alloc(u8, name.len);
    @memcpy(new_name, name);
    return .{
        .archive = archive,
        .inode = inode,
        .name = new_name,
    };
}
pub fn fromEntry(archive: *Archive, entry: DirEntry) !SfsFile {
    var rdr = try archive.fil.readerAt(entry.block_start + archive.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(archive.allocator(), &rdr.interface, &archive.decomp);
    try meta.interface.discardAll(entry.block_offset);
    const inode: Inode = try .read(archive.allocator(), &meta.interface, archive.super.block_size);
    errdefer inode.deinit(archive.allocator());
    return .init(archive, inode, entry.name);
}

pub fn deinit(self: SfsFile) void {
    var alloc = self.archive.allocator();
    alloc.free(self.name);
    self.inode.deinit(alloc);
}

fn getEntries(self: SfsFile) ![]DirEntry {
    return self.inode.dirEntries(self.archive);
}

pub fn ownerUid(self: SfsFile) !u16 {
    return self.archive.id(self.inode.hdr.uid_idx);
}
pub fn ownerGid(self: SfsFile) !u16 {
    return self.archive.id(self.inode.hdr.gid_idx);
}
pub fn permissions(self: SfsFile) u16 {
    return self.inode.hdr.permissions;
}

pub fn isRegular(self: SfsFile) bool {
    return switch (self.inode.hdr.inode_type) {
        .file, .ext_file => true,
        else => false,
    };
}
/// The returned DataReader will no longer work if the File's deinit function is called
/// or, more specifically, it's inode's deinit function is called.
pub fn dataReader(self: SfsFile) !DataReader {
    return self.inode.dataReader(self.archive);
}

pub fn isDir(self: SfsFile) bool {
    return switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => true,
        else => false,
    };
}
pub fn iterate(self: SfsFile) !Iterator {
    if (!self.isDir()) return FileError.NotDirectory;
    return .{
        .entries = try self.getEntries(),
        .archive = self.archive,
    };
}
/// Open a sub-file/folder within a directory at the given path.
/// If path is "", ".", "/", or "./", this File is returned.
pub fn open(self: SfsFile, path: []const u8) !SfsFile {
    if (!self.isDir()) return FileError.NotDirectory;
    if (pathIsSelf(path)) return self;

    // Recursively stip ending & leading path separators.
    if (path[0] == '/') return self.open(path[1..]);
    if (path[path.len - 1] == '/') return self.open(path[0 .. path.len - 1]);

    const idx = std.mem.indexOf(u8, path, "/") orelse path.len;
    const first_element = path[0..idx];
    if (std.mem.eql(u8, first_element, ".")) return self.open(path[idx + 1 ..]);
    const entries = try self.getEntries();
    defer {
        var alloc = self.archive.allocator();
        for (entries) |e| {
            e.deinit(alloc);
        }
        alloc.free(entries);
    }
    var cur_slice = entries;
    var split = cur_slice.len / 2;
    while (cur_slice.len > 0) {
        split = cur_slice.len / 2;
        const comp = std.mem.order(u8, first_element, cur_slice[split].name);
        switch (comp) {
            .eq => {
                var fil: SfsFile = try .fromEntry(self.archive, cur_slice[split]);
                if (idx == path.len) {
                    return fil;
                }
                defer fil.deinit();
                return fil.open(path[idx + 1 ..]);
            },
            .lt => cur_slice = cur_slice[0..split],
            .gt => cur_slice = cur_slice[split + 1 ..],
        }
    }
    return FileError.NotFound;
}

pub fn isSymlink(self: SfsFile) bool {
    return switch (self.inode.hdr.inode_type) {
        .symlink, .ext_symlink => true,
        else => false,
    };
}
pub fn symlinkPath(self: SfsFile) ![]const u8 {
    if (!self.isSymlink()) return FileError.NotSymlink;
    return switch (self.inode.data) {
        .symlink => |s| s.target,
        .ext_symlink => |s| s.target,
        else => unreachable,
    };
}

/// Check if the File is a block or character device.
pub fn isDevice(self: SfsFile) bool {
    return switch (self.inode.hdr.inode_type) {
        .block_dev, .char_dev, .ext_block_dev, .ext_char_dev => true,
        else => false,
    };
}
/// If the File is a block or character device, get's it's device number.
pub fn devNum(self: SfsFile) !u32 {
    if (!self.isDevice()) return FileError.NotDevice;
    return switch (self.inode.data) {
        .block_dev, .char_dev => |d| d.dev,
        .ext_block_dev, .ext_char_dev => |d| d.dev,
        else => unreachable,
    };
}

/// Extract the given File to the path. If File is a regular file, the path must be a directory or not exist.
/// If the gievn path is a folder, the File's contents will be extracted within.
pub fn extract(self: *SfsFile, path: []const u8, options: ExtractionOptions) !void {
    var alloc = self.archive.allocator();
    var ext_path: []u8 = undefined;
    if (std.fs.cwd().statFile(path)) |stat| {
        if (stat.kind == .directory) {
            if (!self.isDir()) {
                const has_end_sep = path[path.len - 1] == '/';
                const alloc_size = if (has_end_sep)
                    path.len + self.name.len
                else
                    path.len + self.name.len + 1;
                ext_path = try alloc.alloc(u8, alloc_size);
                @memcpy(ext_path[0..path.len], path);
                @memcpy(ext_path[ext_path.len - self.name.len ..], self.name);
                if (!has_end_sep) ext_path[path.len] = '/';
            } else {
                ext_path = @constCast(path);
            }
        } else return FileError.ExtractionPathExists;
    } else |err| {
        if (err == error.FileNotFound) {
            ext_path = @constCast(path);
        } else {
            std.log.err("Error stat-ing extraction path {s}: {}\n", .{ path, err });
            return err;
        }
    }
    defer if (ext_path.len > path.len) alloc.free(ext_path);
    //TODO: switch to threaded version.
    return self.inode.extractTo(self.archive, path, options);
}

/// Utility function.
pub fn pathIsSelf(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len == 1 and (path[0] == '/' or path[0] == '.')) return true;
    if (path.len == 2 and (path[0] == '.' and path[1] == '/')) return true;
    return false;
}

pub const Iterator = struct {
    entries: []DirEntry,
    archive: *Archive,

    idx: u32 = 0,

    pub fn next(self: *Iterator) !?SfsFile {
        if (self.idx >= self.entries.len) return null;
        defer self.idx += 1;
        return try SfsFile.fromEntry(self.archive, self.entries[self.idx]);
    }
    pub fn deinit(self: Iterator) void {
        var alloc = self.archive.allocator();
        for (self.entries) |e| {
            e.deinit(alloc);
        }
        alloc.free(self.entries);
    }
};

const std = @import("std");
const io = std.io;

const inode = @import("inode/inode.zig");

const Reader = @import("reader.zig").Reader;
const DirEntry = @import("directory.zig").DirEntry;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const FileError = error{
    NotDirectory,
    NotNormalFile,
    NotSymlink,
};

pub const File = struct {
    name: []const u8,
    inode: inode.Inode,

    // pub fn fromDirEntry(read: Reader, ent: DirEntry) !File {}

    pub fn open(self: File, reader: *Reader, path: []const u8) !File {
        if (path.len == 0 || std.mem.eql(u8, path, ".")) {
            return self;
        }
        switch (inode.InodeHeader.inode_type) {
            .dir, .ext_dir => {},
            else => return FileError.NotDirectory,
        }
        _ = reader;
        //TODO: read dir entries and find correct inode and file
    }

    pub fn symPath(self: File) ![]const u8 {
        return switch (self.inode.data) {
            .sym => |s| s.target,
            .ext_sym => |s| s.target,
            else => FileError.NotSymlink,
        };
    }
};

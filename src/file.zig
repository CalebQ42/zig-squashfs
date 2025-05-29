const std = @import("std");

const Reader = @import("reader.zig").Reader;
const Inode = @import("inode/inode.zig").Inode;
const DirEntry = @import("directory.zig").DirEntry;
const DecompressType = @import("decompress.zig").DecompressType;
const FileHolder = @import("readers/file_holder.zig").FileHolder;
const DataReader = @import("readers/data_reader.zig").DataReader;
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const FileTypes = enum {
    Regular,
    Dir,
    Symlink,
    Misc,
};

pub const FileError = error{
    NotFound,
};

pub const File = union(enum) {
    Regular: RegularFile,
    Dir: DirFile,
    Symlink: SymlinkFile,
    Misc: MiscFile,

    const Self = @This();

    fn fromDirEntry(alloc: std.mem.Allocator, holder: *FileHolder, decomp: DecompressType, inode_start: u64, dir_start: u64, block_size: u32, ent: DirEntry) !File {
        const offset_rdr = holder.readerAt(inode_start + ent.block_start);
        var meta_rdr: MetadataReader = .init(alloc, decomp, offset_rdr);
        const inode: Inode = try .init(alloc, meta_rdr, block_size);
        return switch (inode.header.inode_type) {

        }
    }

    fn fromDirEntryReader(rdr: *Reader, ent: DirEntry) !File {
        return fromDirEntry(rdr.alloc, &rdr.holder, rdr.super.decomp, rdr.super.inode_table_start, rdr.super.dir_table_start, ent);
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .Regular => |f| f.deinit(),
            .Dir => |d| d.deinit(),
            .Symlink => |s| s.deinit(),
            else => {},
        }
    }
};

pub const RegularFile = struct {
    alloc: std.mem.Allocator,
    fil: *FileHolder,
    decomp: DecompressType,

    inode: Inode,

    data_rdr: DataReader,

    fn init(alloc: std.mem.Allocator, fil: *FileHolder, decomp: DecompressType, inode: Inode) !RegularFile{
        return .{
            .alloc = alloc,
            .fil = fil,
            .decomp = decomp,
            .inode = inode,
            .data_rdr = try .init()
        }
    }

    pub fn deinit(self: RegularFile) void {
        self.inode.deinit();
        self.data_rdr.deinit();
    }

    pub fn size(self: RegularFile) u64 {
        return switch (self.inode.data) {
            .file => |f| f.size,
            .ext_file => |f| f.size,
            else => unreachable,
        };
    }

    pub fn read(self: *RegularFile, bytes: []u8) !usize {
        return self.data_rdr.read(bytes);
    }

    const FileReader = std.io.GenericReader(*RegularFile, anyerror, read);

    pub fn reader(self: *RegularFile) FileReader {
        return .{
            .context = self,
        };
    }
};

pub const DirFile = struct {
    alloc: std.mem.Allocator,
    fil: *FileHolder,

    inode: Inode,

    dirEntries: []DirEntry,

    pub fn deinit(self: *DirFile) void {
        self.alloc.free(self.dirEntries);
        self.inode.deinit();
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
        try self.readDirEntries(rdr);
        const split_idx = std.mem.indexOf(u8, clean_path, "/") orelse clean_path.len;
        const name = clean_path[0..split_idx];
        const ent = self.dirEntries.?.get(name);
        if (ent == null) {
            return FileError.NotFound;
        }
        var fil: File = try .fromDirEntry(rdr, ent.?);
        return fil.realOpen(rdr, clean_path[split_idx..], false);
    }
};

pub const SymlinkFile = struct {
    alloc: std.mem.Allocator,

    inode: Inode,

    pub fn deinit(self: *SymlinkFile) void {
        self.inode.deinit();
    }

    pub fn symPath(self: SymlinkFile) []const u8 {
        return switch (self.inode.data) {
            .sym => |s| s.target,
            .ext_sym => |s| s.target,
            else => unreachable,
        };
    }
};

pub const MiscFile = struct {
    fil: *FileHolder,

    inode: Inode,
};

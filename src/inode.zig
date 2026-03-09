//! A file-system object. Represents a File or directory.

const std = @import("std");
const Reader = std.Io.Reader;
const WaitGroup = std.Thread.WaitGroup;
const Pool = std.Thread.Pool;
const Mutex = std.Thread.Mutex;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const dir = @import("inode_data/dir.zig");
const file = @import("inode_data/file.zig");
const misc = @import("inode_data/misc.zig");
const Tables = @import("tables.zig");
const DataReader = @import("util/data.zig");
const ThreadedDataReader = @import("util/data_threaded.zig");
const InodeExtract = @import("util/extract.zig");
const InodeFinish = @import("util/inode_finish.zig");
const FinishUnion = InodeFinish.FinishUnion;
const MetadataReader = @import("util/metadata.zig");

pub const Ref = packed struct {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const InodeType = enum(u16) {
    dir = 1,
    file,
    symlink,
    block_dev,
    char_dev,
    fifo,
    socket,
    ext_dir,
    ext_file,
    ext_symlink,
    ext_block_dev,
    ext_char_dev,
    ext_fifo,
    ext_socket,
};

pub const InodeData = union(InodeType) {
    dir: dir.Dir,
    file: file.File,
    symlink: misc.Symlink,
    block_dev: misc.Dev,
    char_dev: misc.Dev,
    fifo: misc.IPC,
    socket: misc.IPC,
    ext_dir: dir.ExtDir,
    ext_file: file.ExtFile,
    ext_symlink: misc.ExtSymlink,
    ext_block_dev: misc.ExtDev,
    ext_char_dev: misc.ExtDev,
    ext_fifo: misc.ExtIPC,
    ext_socket: misc.ExtIPC,
};

pub const Header = packed struct {
    inode_type: InodeType,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

const Inode = @This();

hdr: Header,
data: InodeData,

pub fn read(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
    var hdr: Header = undefined;
    try rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    return .{
        .hdr = hdr,
        .data = switch (hdr.inode_type) {
            .dir => .{ .dir = try .read(rdr) },
            .file => .{ .file = try .read(alloc, rdr, block_size) },
            .symlink => .{ .symlink = try .read(alloc, rdr) },
            .block_dev => .{ .block_dev = try .read(rdr) },
            .char_dev => .{ .char_dev = try .read(rdr) },
            .fifo => .{ .fifo = try .read(rdr) },
            .socket => .{ .socket = try .read(rdr) },
            .ext_dir => .{ .ext_dir = try .read(rdr) },
            .ext_file => .{ .ext_file = try .read(alloc, rdr, block_size) },
            .ext_symlink => .{ .ext_symlink = try .read(alloc, rdr) },
            .ext_block_dev => .{ .ext_block_dev = try .read(rdr) },
            .ext_char_dev => .{ .ext_char_dev = try .read(rdr) },
            .ext_fifo => .{ .ext_fifo = try .read(rdr) },
            .ext_socket => .{ .ext_socket = try .read(rdr) },
        },
    };
}
pub fn readFromEntry(alloc: std.mem.Allocator, archive: Archive, entry: DirEntry) !Inode {
    var rdr = try archive.fil.readerAt(archive.super.inode_start + entry.block_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
    try meta.interface.discardAll(entry.block_offset);
    return read(alloc, &meta.interface, archive.super.block_size);
}

pub fn deinit(self: Inode, alloc: std.mem.Allocator) void {
    switch (self.data) {
        .file => |f| alloc.free(f.block_sizes),
        .ext_file => |f| alloc.free(f.block_sizes),
        .symlink => |s| alloc.free(s.target),
        .ext_symlink => |s| alloc.free(s.target),
        else => {},
    }
}

/// Get the data reader for a file inode.
pub fn dataReader(self: Inode, alloc: std.mem.Allocator, archive: Archive, tables: *Tables) !DataReader {
    return switch (self.hdr.inode_type) {
        .file => readerFromData(alloc, archive, tables, self.data.file),
        .ext_file => readerFromData(alloc, archive, tables, self.data.ext_file),
        else => error.NotRegularFile,
    };
}
fn readerFromData(alloc: std.mem.Allocator, archive: Archive, tables: *Tables, data: anytype) !DataReader {
    var out: DataReader = .init(alloc, archive, data.block_sizes, data.block_start, data.size);
    if (data.frag_idx != 0xFFFFFFFF)
        out.addFragment(try tables.frag_table.get(data.frag_idx), data.frag_block_offset);
    return out;
}

/// Get the directory entries for a directory inode.
pub fn dirEntries(self: Inode, alloc: std.mem.Allocator, archive: Archive) ![]DirEntry {
    return switch (self.hdr.inode_type) {
        .dir => entriesFromData(alloc, archive, self.data.dir),
        .ext_dir => entriesFromData(alloc, archive, self.data.ext_dir),
        else => error.NotDirectory,
    };
}
fn entriesFromData(alloc: std.mem.Allocator, archive: Archive, data: anytype) ![]DirEntry {
    var rdr = try archive.fil.readerAt(archive.super.dir_start + data.block_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, archive.decomp);
    try meta.interface.discardAll(data.block_offset);
    return DirEntry.readDir(alloc, &meta.interface, data.size);
}

/// Returns the xattr index for the given inode. If the inode isn't an extended variant or doesn't have any, the u32 max is returned (0xFFFFFFFF).
pub fn xattrIdx(self: Inode) u32 {
    return switch (self.data) {
        .ext_dir => |d| d.xattr_id,
        .ext_file => |f| f.xattr_idx,
        .ext_symlink => |s| s.xattr_idx,
        .ext_block_dev, .ext_char_dev => |d| d.xattr_idx,
        .ext_fifo, .ext_socket => |i| i.xattr_idx,
        else => 0xFFFFFFFF,
    };
}

/// Applies the Inode's metadata to the given File.
/// Mod time is always set, but permissions and xattrs are set based on the given ExtractionOptions.
pub fn setMetadata(self: Inode, alloc: std.mem.Allocator, tables: *Tables, fil: std.fs.File, options: ExtractionOptions) !void {
    const time = @as(i128, self.hdr.mod_time) * 1000000000;
    try fil.updateTimes(time, time);
    if (!options.ignore_permissions) {
        try fil.chmod(self.hdr.permissions);
        try fil.chown(try tables.id_table.get(self.hdr.uid_idx), try tables.id_table.get(self.hdr.gid_idx));
    }
    if (!options.ignore_xattr) {
        const idx = self.xattrIdx();
        if (idx == 0xFFFFFFFF) return;
        const xattrs = try tables.xattr_table.get(alloc, idx);
        defer alloc.free(xattrs);
        for (xattrs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.key, kv.value.ptr, kv.value.len, 0);
            alloc.free(kv.key);
            alloc.free(kv.value);
            if (res != 0) {
                if (options.verbose)
                    options.verbose_writer.?.print("fsetxattr has result of: {}\n", .{res}) catch {};
                return error.SetXattr;
            }
        }
    }
}

/// Extract the inode to the given path.
pub fn extractTo(self: Inode, alloc: std.mem.Allocator, archive: Archive, path: []const u8, options: ExtractionOptions) !void {
    return InodeExtract.extractTo(alloc, self, archive, path, options);
}

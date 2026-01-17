const std = @import("std");
const WaitGroup = std.Thread.WaitGroup;
const Mutex = std.Thread.Mutex;

const Archive = @import("archive.zig");
const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("util/metadata.zig");

const FileError = error{
    NotDirectory,
    NotRegularFile,
    NotFound,
};

const File = @This();

archive: *Archive,

inode: Inode,
name: []const u8,

/// Initialize a new File.
/// name is copied to the File so can be safely freed afterwards.
pub fn init(archive: *Archive, inode: Inode, name: []const u8) !File {
    const new_name = try archive.allocator().alloc(u8, name.len);
    @memcpy(new_name, name);
    return .{
        .archive = archive,
        .inode = inode,
        .name = new_name,
    };
}
pub fn fromEntry(archive: *Archive, entry: DirEntry) !File {
    var rdr = try archive.fil.readerAt(entry.block_start + archive.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(archive.allocator(), &rdr.interface, &archive.decomp);
    try meta.interface.discardAll(entry.block_offset);
    const inode: Inode = try .read(archive.allocator(), &meta.interface, archive.super.block_size);
    errdefer inode.deinit(archive.allocator());
    const new_name = try archive.allocator().alloc(u8, entry.name.len);
    @memcpy(new_name, entry.name);
    return .init(archive, inode, new_name);
}

pub fn deinit(self: File) void {
    var alloc = self.archive.allocator();
    alloc.free(self.name);
    self.inode.deinit(alloc);
}

fn getEntries(self: File) ![]DirEntry {
    if (!self.isDir()) return FileError.NotDirectory;
    var block_start: u32 = undefined;
    var block_offset: u16 = undefined;
    var size: u32 = undefined;
    switch (self.inode.data) {
        .dir => |d| {
            block_start = d.block_start;
            block_offset = d.block_offset;
            size = d.size;
        },
        .ext_dir => |d| {
            block_start = d.block_start;
            block_offset = d.block_offset;
            size = d.size;
        },
        else => unreachable,
    }
    var rdr = try self.archive.fil.readerAt(self.archive.super.dir_start + block_start, &[0]u8{});
    const alloc = self.archive.allocator();
    var meta: MetadataReader = .init(alloc, &rdr.interface, &self.archive.decomp);
    try meta.interface.discardAll(block_offset);
    return DirEntry.readDir(alloc, &rdr.interface, size);
}

pub fn isDir(self: File) bool {
    return switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => true,
        else => false,
    };
}

/// Open a file/folder within a directory at the given path.
/// If path is ".", "/", or "./", this File is returned.
pub fn open(self: File, path: []const u8) !File {
    if (!self.isDir()) return FileError.NotDirectory;
    if (pathIsSelf(path)) return self;
    // Recursively stip ending & leading path separators.
    // TODO: potentially do this more efficiently or have stricter requirements.
    if (path[0] == '/') return self.open(path[1..]);
    if (path[path.len - 1] == '/') return self.open(path[0 .. path.len - 1]);
    const idx = std.mem.indexOf(u8, path, "/") orelse path.len;
    const first_element = path[0..idx];
    if (std.mem.eql(u8, first_element, ".")) return self;
    const entries = try self.getEntries();
    var cur_slice = entries;
    var split = cur_slice.len / 2;
    while (cur_slice.len == 0) {
        split = cur_slice.len / 2;
        const comp = std.mem.order(u8, entries[split].name, first_element);
        switch (comp) {
            .eq => {
                var fil: File = try .fromEntry(self.archive, cur_slice[split]);
                if (idx == path.len) {
                    return fil;
                }
                defer fil.deinit();
                return fil.open(path[idx + 1 ..]);
            },
            .lt => cur_slice = cur_slice[0..split],
            .gt => cur_slice = cur_slice[split..],
        }
    }
    return FileError.NotFound;
}

pub fn extract(self: *File, path: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = path;
    _ = options;
    return error.TODO;
}

const ParentInfo = struct {
    fil: *File,
};

fn extractReal(self: *File, path: []const u8, options: ExtractionOptions) void {
    _ = self;
    _ = path;
    _ = options;
}

pub fn pathIsSelf(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len == 1 and (path[0] == '/' or path[0] == '.')) return true;
    if (path.len == 2 and (path[0] == '.' and path[1] == '/')) return true;
    return false;
}

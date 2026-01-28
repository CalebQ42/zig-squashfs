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
    InvalidExtractionPath,
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

pub fn ownerUid(self: File) !u16 {
    return self.archive.id(self.inode.hdr.uid_idx);
}
pub fn ownerGid(self: File) !u16 {
    return self.archive.id(self.inode.hdr.gid_idx);
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
    return DirEntry.readDir(alloc, &meta.interface, size);
}

pub fn isDir(self: File) bool {
    return switch (self.inode.hdr.inode_type) {
        .dir, .ext_dir => true,
        else => false,
    };
}
pub fn iter(self: File) !Iterator {
    var entries = try self.getEntries();
    return error.TODO;
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
    if (std.mem.eql(u8, first_element, ".")) return self.open(path[idx + 1 ..]);
    const entries = try self.getEntries();
    var cur_slice = entries;
    var split = cur_slice.len / 2;
    while (cur_slice.len > 0) {
        split = cur_slice.len / 2;
        const comp = std.mem.order(u8, first_element, cur_slice[split].name);
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
            .gt => cur_slice = cur_slice[split + 1 ..],
        }
    }
    return FileError.NotFound;
}

pub fn extract(self: *File, path: []const u8, options: ExtractionOptions) !void {
    std.Options = .{
        .log_level = options.log_level,
    };
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
                ext_path = alloc.alloc(u8, alloc_size);
                @memcpy(ext_path[0..path.len], path);
                @memcpy(ext_path[ext_path.len - self.name.len ..], self.name);
                if (!has_end_sep) ext_path[path.len] = '/';
            } else {
                ext_path = path;
            }
        } else return FileError.InvalidExtractionPath;
    } else |err| {
        if (err == .FileNotFound) {
            ext_path = path;
        } else {
            std.log.err("Error stat-ing extraction path {s}: {}\n", .{ path, err });
            return err;
        }
    }
    defer if (ext_path.len > path.len) alloc.free(ext_path);
    var pool: std.Thread.Pool = .{};
    try pool.init(.{ .allocator = alloc });
    var wg: WaitGroup = .{};
    defer pool.deinit();
    var err: ?anyerror = null;
    self.extractReal(ext_path, options, &pool, &wg, &err, null);
    wg.wait();
    if (err != null) return err.?;
}

const ParentInfo = struct {
    fil: *File,
    mut: Mutex = .{},

    fn finish(self: *ParentInfo) void {}
};

fn extractReal(self: *File, path: []const u8, options: ExtractionOptions, pol: *std.Thread.Pool, wg: *WaitGroup, out_err: *?anyerror, parent: ?ParentInfo) void {
    std.log.info("Extracting {s} (inode {}) to {s}\n", .{ self.name, self.inode.hdr.num, path });
    defer if (parent != null) parent.?.finish();
    switch (self.inode.hdr.inode_type) {
        .file, .ext_file => {
            var fil = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.log.err("Error creating {}: {}\n", .{ path, err });
                out_err = err;
                return;
            };
            //TODO:
            self.setPerm(fil, options) catch |err| {
                std.log.err("Error setting permissions for {}: {}\n", .{ path, err });
                out_err = err;
                return;
            };
        },
        .symlink, .ext_symlink => {},
        .block_dev,
        .char_dev,
        .fifo,
        .ext_block_dev,
        .ext_char_dev,
        .ext_fifo,
        => {},
        .dir, .ext_dir => {
            var parent_info: ParentInfo = .{
                .fil = self,
            };
            var dir_wg: WaitGroup = .{};
            var iter: Iterator = self.iter() catch |err| {};
        },
        .socket, .ext_socket => {
            std.log.info("Ignoring socket file {s} (inode {})\n", .{ self.name, self.inode.hdr.num });
        },
    }
}

pub fn setPerm(self: File, fil: *std.fs.File, options: ExtractionOptions) !void {
    if (!options.ignoreOwner) try fil.chmod(self.inode.hdr.permissions);
    if (!options.ignorePermissions) try fil.chown(try self.ownerUid(), try self.ownerGid());
}

pub fn pathIsSelf(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path.len == 1 and (path[0] == '/' or path[0] == '.')) return true;
    if (path.len == 2 and (path[0] == '.' and path[1] == '/')) return true;
    return false;
}

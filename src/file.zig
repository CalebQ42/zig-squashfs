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
    const new_name = try archive.allocator().alloc(u8, entry.name.len);
    @memcpy(new_name, entry.name);
    return .init(archive, inode, new_name);
}

pub fn deinit(self: SfsFile) void {
    var alloc = self.archive.allocator();
    alloc.free(self.name);
    self.inode.deinit(alloc);
}

fn getEntries(self: SfsFile) ![]DirEntry {
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
    if (!self.isRegular()) return FileError.NotRegularFile;
    var frag_idx: u32 = undefined;
    var frag_offset: u32 = undefined;
    var size: u64 = undefined;
    var blocks: []BlockSize = undefined;
    var start: u64 = undefined;
    switch (self.inode.data) {
        .file => |f| {
            frag_idx = f.frag_idx;
            frag_offset = f.frag_block_offset;
            size = f.size;
            blocks = f.block_sizes;
            start = f.block_start;
        },
        .ext_file => |f| {
            frag_idx = f.frag_idx;
            frag_offset = f.frag_block_offset;
            size = f.size;
            blocks = f.block_sizes;
            start = f.block_start;
        },
        else => unreachable,
    }
    var out: DataReader = .init(self.archive, blocks, start, size);
    if (frag_idx != 0xFFFFFFFF)
        out.addFragment(try self.archive.frag(frag_idx), frag_offset);
    return out;
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
/// If path is ".", "/", or "./", this File is returned.
pub fn open(self: SfsFile, path: []const u8) !SfsFile {
    if (!self.isDir()) return FileError.NotDirectory;
    if (pathIsSelf(path)) return self;
    // Recursively stip ending & leading path separators.
    // TODO: potentially do this more efficiently or have stricter path requirements.
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
pub fn dev(self: SfsFile) !u32 {
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
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = alloc });
    var wg: WaitGroup = .{};
    defer pool.deinit();
    var err: ?anyerror = null;
    wg.start();
    self.extractReal(ext_path, options, &pool, &wg, &err, null);
    wg.wait();
    if (err != null) return err.?;
}

const ParentInfo = struct {
    sfs_fil: SfsFile,
    path: []const u8,
    mut: *Mutex,
    dir_wg: *WaitGroup,
    parent_wg: *WaitGroup,
    options: ExtractionOptions,
    err: *?anyerror,

    fn finish(self: *const ParentInfo) void {
        self.mut.lock();
        if (!self.dir_wg.isDone()) {
            self.mut.unlock();
            return;
        }
        self.mut.unlock();
        self.sfs_fil.archive.allocator().destroy(self.mut);
        self.sfs_fil.archive.allocator().destroy(self.dir_wg);
        defer self.parent_wg.finish();
        var fil = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            std.log.err("Error opening folder {s} to set permissions: {}\n", .{ self.path, err });
            self.err.* = err;
            return;
        };
        defer fil.close();
        self.sfs_fil.setPerm(fil, self.options) catch |err| {
            std.log.err("Error setting permissions to {s}: {}\n", .{ self.path, err });
            self.err.* = err;
            return;
        };
    }
};

fn extractReal(self: SfsFile, path: []const u8, options: ExtractionOptions, pol: *std.Thread.Pool, wg: *WaitGroup, out_err: *?anyerror, parent: ?ParentInfo) void {
    std.log.info("Extracting {s} (inode {}) to {s}\n", .{ self.name, self.inode.hdr.num, path });
    defer {
        if (parent != null) {
            parent.?.finish();
            self.archive.allocator().free(path);
            self.deinit();
        } else {
            wg.finish();
        }
    }
    if (out_err.* != null) {
        return;
    }
    switch (self.inode.hdr.inode_type) {
        .file, .ext_file => {
            var fil = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.log.err("Error creating {s}: {}\n", .{ path, err });
                out_err.* = err;
                return;
            };
            defer fil.close();
            var dat_rdr = self.dataReader() catch |err| {
                std.log.err("Error getting data reader for {s} (inode {}): {}\n", .{ self.name, self.inode.hdr.num, err });
                out_err.* = err;
                return;
            };
            defer dat_rdr.deinit();
            var wrt = fil.writer(&[0]u8{});
            _ = dat_rdr.interface.streamRemaining(&wrt.interface) catch |err| {
                std.log.err("Error writing data for {s} (inode {}) to {s}: {}\n", .{ self.name, self.inode.hdr.num, path, err });
                out_err.* = wrt.err orelse err;
                return;
            };
            wrt.interface.flush() catch |err| {
                std.log.err("Error flushing data for {s} (inode {}) to {s}: {}\n", .{ self.name, self.inode.hdr.num, path, err });
                out_err.* = wrt.err orelse err;
                return;
            };
            self.setPerm(fil, options) catch |err| {
                std.log.err("Error setting permissions/owner for {s}: {}\n", .{ path, err });
                out_err.* = err;
                return;
            };
        },
        .symlink, .ext_symlink => {
            //TODO: deal with dereference symlink options
            const target_path = self.symlinkPath() catch |err| {
                std.log.err("Error getting symlink target path for {s} (inode {}): {}\n", .{ self.name, self.inode.hdr.num, err });
                out_err.* = err;
                return;
            };
            std.fs.cwd().symLink(target_path, path, .{}) catch |err| {
                std.log.err("Error creating {s}: {}\n", .{ path, err });
                out_err.* = err;
                return;
            };
            // self.setPerm(fil, options) catch |err| {
            //     std.log.err("Error setting permissions/owner for {s}: {}\n", .{ path, err });
            //     out_err.* = err;
            //     return;
            // };
        },
        .block_dev,
        .char_dev,
        .fifo,
        .ext_block_dev,
        .ext_char_dev,
        .ext_fifo,
        => {
            var mode: u32 = undefined;
            var fil_dev: u32 = 0;
            switch (self.inode.hdr.inode_type) {
                .block_dev, .ext_block_dev => {
                    mode = std.posix.DT.BLK;
                    fil_dev = self.dev() catch |err| {
                        std.log.err("Error getting device number for {s} (inode {}): {}\n", .{ self.name, self.inode.hdr.num, err });
                        out_err.* = err;
                        return;
                    };
                },
                .char_dev, .ext_char_dev => {
                    mode = std.posix.DT.CHR;
                    fil_dev = self.dev() catch |err| {
                        std.log.err("Error getting device number for {s} (inode {}): {}\n", .{ self.name, self.inode.hdr.num, err });
                        out_err.* = err;
                        return;
                    };
                },
                else => mode = std.posix.DT.FIFO,
            }
            const res = std.os.linux.mknod(@ptrCast(path), mode, fil_dev);
            if (res != 0) {
                std.log.err("Error creating device file at {s} with code {}\n", .{ path, res });
                out_err.* = error.MknodError;
                return;
            }
            const fil = std.fs.cwd().openFile(path, .{}) catch |err| {
                std.log.err("Error openning {s} to set permissions: {}\n", .{ path, err });
                out_err.* = err;
                return;
            };
            defer fil.close();
            self.setPerm(fil, options) catch |err| {
                std.log.err("Error setting permissions/owner for {s}: {}\n", .{ path, err });
                out_err.* = err;
                return;
            };
        },
        .dir, .ext_dir => {
            if (std.fs.cwd().statFile(path)) |stat| {
                if (stat.kind != .directory) {
                    std.log.err("{s} exists and is not a folder\n", .{path});
                    out_err.* = FileError.ExtractionPathExists;
                    return;
                }
            } else |err| {
                if (err == error.FileNotFound) {
                    std.fs.cwd().makeDir(path) catch |err_2| {
                        std.log.err("Error creating {s}: {}\n", .{ path, err_2 });
                        out_err.* = err;
                        return;
                    };
                } else {
                    std.log.err("Error checking if {s} exists: {}\n", .{ path, err });
                    out_err.* = err;
                    return;
                }
            }
            var dir_wg: *WaitGroup = self.archive.allocator().create(WaitGroup) catch |err| {
                std.log.err("Error allocating waitgroup for {s} (inode {}): {}\n", .{ path, self.inode.hdr.num, err });
                out_err.* = err;
                return;
            };
            const parent_info: ParentInfo = .{
                .sfs_fil = self,
                .path = path,
                .mut = self.archive.allocator().create(Mutex) catch |err| {
                    std.log.err("Error allocating mutex for {s} (inode {}): {}\n", .{ path, self.inode.hdr.num, err });
                    out_err.* = err;
                    return;
                },
                .dir_wg = dir_wg,
                .parent_wg = wg,
                .options = options,
                .err = out_err,
            };
            var iter: Iterator = self.iterate() catch |err| {
                std.log.err("Error getting iterator for {s} (inode {}): {}\n", .{ path, self.inode.hdr.num, err });
                out_err.* = err;
                return;
            };
            defer iter.deinit();
            const path_has_end_sep = path[path.len - 1] == '/';
            while (true) {
                const iter_fil = iter.next() catch |err| {
                    std.log.err("Error getting next iterator value {s} (inode {}): {}\n", .{ path, self.inode.hdr.num, err });
                    out_err.* = err;
                    break;
                };
                if (iter_fil == null) break;
                const fil = iter_fil.?;
                dir_wg.start();
                var path_len = path.len + fil.name.len;
                if (!path_has_end_sep) path_len += 1;
                var new_path = self.archive.allocator().alloc(u8, path_len) catch |err| {
                    std.log.err("Error allocating subpath for {s} (inode {}): {}\n", .{ path, self.inode.hdr.num, err });
                    out_err.* = err;
                    dir_wg.finish();
                    break;
                };
                @memcpy(new_path[0..path.len], path);
                @memcpy(new_path[new_path.len - fil.name.len ..], fil.name);
                if (!path_has_end_sep) new_path[path.len] = '/';
                pol.spawn(extractReal, .{
                    fil,
                    new_path,
                    options,
                    pol,
                    wg,
                    out_err,
                    parent_info,
                }) catch |err| {
                    std.log.err("Error starting sub-file extraction thread: {}\n", .{err});
                    out_err.* = err;
                    dir_wg.finish();
                    break;
                };
            }
        },
        .socket, .ext_socket => {
            std.log.info("Ignoring socket file {s} (inode {})\n", .{ self.name, self.inode.hdr.num });
        },
    }
}

fn setPerm(self: SfsFile, fil: File, options: ExtractionOptions) !void {
    if (!options.ignoreOwner) try fil.chmod(self.inode.hdr.permissions);
    if (!options.ignorePermissions) try fil.chown(try self.ownerUid(), try self.ownerGid());
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

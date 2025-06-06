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
    parent_path: []const u8,

    dirEntries: ?std.StringHashMap(DirEntry) = null,
    data_rdr: ?DataReader = null,

    pub const FileError = error{
        NotDirectory,
        NotNormalFile,
        NotSymlink,
        NotFound,
    };

    fn fromDirEntry(rdr: *Reader, ent: DirEntry, parent_path: []const u8) !File {
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
        var out: File = .{
            .name = name,
            .inode = try .init(
                rdr.alloc,
                meta_rdr.any(),
                rdr.super.block_size,
            ),
            .parent_path = parent_path,
        };
        switch (out.inode.header.inode_type) {
            .file, .ext_file => {
                out.data_rdr = try .init(&out, rdr);
            },
            else => {},
        }
        return out;
    }

    pub fn file_path(self: File, alloc: std.mem.Allocator) ![]u8 {
        if (self.parent_path.len == 0) {
            const out = try alloc.alloc(u8, self.name.len);
            @memcpy(out, self.name);
            return out;
        }
        return std.mem.concat(alloc, u8, &[3][]const u8{ self.parent_path, "/", self.name });
    }

    pub fn uid(self: File, rdr: *Reader) !u32 {
        return rdr.id_table.getValue(rdr, self.inode.header.uid_idx);
    }

    pub fn gid(self: File, rdr: *Reader) !u32 {
        return rdr.id_table.getValue(rdr, self.inode.header.gid_idx);
    }

    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        self.inode.deinit();
        alloc.free(self.name);
        alloc.free(self.parent_path);
        if (self.data_rdr != null) self.data_rdr.?.deinit();
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
        var fil = try fromDirEntry(rdr, ent.?, try self.file_path(rdr.alloc));
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
        errdefer rdr.alloc.free(files);
        var dirEntryIter = self.dirEntries.?.valueIterator();
        var i: u32 = 0;
        while (dirEntryIter.next()) |ent| : (i += 1) {
            files[i] = try .fromDirEntry(rdr, ent.*, try self.file_path(rdr.alloc));
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
        var siz: u32 = 0;
        switch (self.inode.data) {
            .dir => |d| {
                block_start = d.block_start;
                offset = d.offset;
                siz = d.size;
            },
            .ext_dir => |d| {
                block_start = d.block_start;
                offset = d.offset;
                siz = d.size;
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
        self.dirEntries = try directory.readDirectory(rdr.alloc, meta_rdr.any(), siz);
    }

    pub fn size(self: File) u64 {
        return switch (self.inode.data) {
            .file => |f| f.size,
            .ext_file => |f| f.size,
            else => 0,
        };
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

    fn extractor(self: *File, rdr: *Reader) !DataExtractor {
        return .init(self, rdr);
    }

    pub const ExtractConfig = struct {
        /// The amount of worker threads to spawn. Defaults to your cpu core count.
        thread_count: u16,
        /// The maximum amount of additional memory this extraction will use.
        /// Default is 1GB or a quarter of your system memory, whichever is smaller.
        /// Actually memory usage will be higher, as this does not account of vaious metadata (such as file names).
        max_mem: u64,
        deref_sym: bool = false,
        unbreak_sym: bool = false,
        verbose: bool = false,
        pub fn init() !ExtractConfig {
            const sys_mem = try std.process.totalSystemMemory();
            return .{
                .thread_count = @truncate(try std.Thread.getCpuCount()),
                .max_mem = @min(sys_mem / 4, 1024 * 1024 * 1024),
            };
        }
    };

    pub const ExtractError = error{
        FileExists,
    };

    /// Extract's the File to the path.
    pub fn extract(self: *File, rdr: *Reader, config: ExtractConfig, path: []const u8) (ExtractError || anyerror)!void {
        var pol: std.Thread.Pool = undefined;
        try pol.init(.{
            .allocator = rdr.alloc,
            .n_jobs = config.thread_count,
        });
        defer pol.deinit();
        return self.extractReal(rdr, config, &pol, path, true);
    }

    fn extractReal(self: *File, rdr: *Reader, config: ExtractConfig, pool: *std.Thread.Pool, path: []const u8, first: bool) (ExtractError || anyerror)!void {
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
                    fs.cwd().makeDir(real_path) catch |err| {
                        if (config.verbose)
                            std.log.err("error creating directory {s}: {any}", .{ real_path, err });
                        return err;
                    };
                }
                var iter = try self.iterator(rdr);
                defer iter.deinit();
                while (iter.next()) |f| {
                    const extr_path = try std.mem.concat(rdr.alloc, u8, &[3][]const u8{ real_path, "/", f.name });
                    defer rdr.alloc.free(extr_path);
                    try f.extractReal(rdr, config, pool, extr_path, false);
                }
            },
            .file, .ext_file => {
                if ((!first and exists) or
                    (first and exists and stat.?.kind != .directory)) return ExtractError.FileExists;
                var extr_path: []u8 = undefined;
                if (first and exists and stat.?.kind == .directory) {
                    extr_path = try std.mem.concat(rdr.alloc, u8, &[3][]const u8{ real_path, "/", self.name });
                } else {
                    extr_path = try rdr.alloc.alloc(u8, real_path.len);
                    @memcpy(extr_path, real_path);
                }
                defer rdr.alloc.free(extr_path);
                var fil = fs.cwd().createFile(extr_path, .{}) catch |err| {
                    if (config.verbose)
                        std.log.err("error creating file {s}: {any}", .{ extr_path, err });
                    return err;
                };
                defer fil.close();
                if (config.thread_count > 1 and self.size() > rdr.super.block_size) {
                    var ext = try self.extractor(rdr);
                    defer ext.deinit();
                    ext.writeToFile(pool, &fil) catch |err| {
                        if (config.verbose)
                            std.log.err("error writing file {s}: {any}", .{ self.name, err });
                        return err;
                    };
                } else {
                    var buf = [1]u8{0} ** 8192;
                    var total_red: u64 = 0;
                    while (total_red < self.size()) {
                        const red = try self.read(&buf);
                        total_red += red;
                    }
                }
            },
            .sym, .ext_sym => {
                //TODO: unbreak symlinks & dereference symlinks
                if (exists) return ExtractError.FileExists;
                fs.cwd().symLink(try self.symPath(), real_path, .{}) catch |err| {
                    if (config.verbose)
                        std.log.err("error creating symlink {s}: {any}", .{ self.name, err });
                    return err;
                };
            },
            .block, .ext_block, .char, .ext_char, .fifo, .ext_fifo => {
                if (exists) return ExtractError.FileExists;
                comptime if (builtin.os.tag != .linux) return;
                const mode: u32 = switch (self.inode.header.inode_type) {
                    .block, .ext_block => std.posix.S.IFBLK,
                    .char, .ext_char => std.posix.S.IFCHR,
                    .fifo, .ext_fifo => std.posix.S.IFIFO,
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
            .sock, .ext_sock => {}, //TODO
        }
        //TODO: permissions
    }
};

const FileIterator = struct {
    alloc: std.mem.Allocator,
    files: []File,

    curIndex: u32 = 0,

    pub fn next(self: *FileIterator) ?*File {
        if (self.curIndex >= self.files.len) return null;
        defer self.curIndex += 1;
        return &self.files[self.curIndex];
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

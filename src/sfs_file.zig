const std = @import("std");

const dir = @import("directory.zig");

const SfsReader = @import("sfs_reader.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const ExtractError = error{
    FileExists,
};

pub const SfsFile = union {
    regular: Regular,
    directory: Dir,
    symlink: Sym,
    other: Other,

    pub fn fromRef(rdr: *SfsReader, ref: Inode.Ref, name: []const u8, parent_path: []const u8) !SfsFile {
        return fromInode(
            rdr,
            try .fromRef(rdr, ref),
            name,
            parent_path,
        );
    }
    pub fn fromDirEntry(rdr: *SfsReader, ent: dir.DirEntry, parent_path: []const u8) !SfsFile {
        const offset_rdr = rdr.rdr.readerAt(ent.block + rdr.super.inode_start);
        var meta_rdr: MetadataReader(@TypeOf(offset_rdr)) = try .init(rdr.alloc, rdr.super.compress, offset_rdr);
        try meta_rdr.skip(ent.offset);
        return fromInode(
            rdr,
            try .init(
                rdr.alloc,
                rdr.super.block_size,
                &meta_rdr,
            ),
            ent.name,
            parent_path,
        );
    }
    pub fn fromInode(rdr: *SfsReader, inode: Inode, name: []const u8, parent_path: []const u8) !SfsFile {
        return switch (inode.hdr.inode_type) {
            .file, .ext_file => .{ .regular = try .init(
                rdr,
                inode,
                name,
                std.mem.trim(parent_path, "/"),
            ) },
            .directory, .ext_directory => .{ .directory = try .init(
                rdr,
                inode,
                name,
                std.mem.trim(parent_path, "/"),
            ) },
            .symlink, .ext_symlink => .{ .symlink = try .init(
                rdr,
                inode,
                name,
                std.mem.trim(parent_path, "/"),
            ) },
            else => .{ .other = try .init(
                rdr,
                inode,
                name,
                std.mem.trim(parent_path, "/"),
            ) },
        };
    }
    pub fn deinit(self: SfsFile) void {
        switch (self) {
            .regular => |r| r.deinit(),
            .directory => |d| d.deinit(),
            .symlink => |s| s.deinit(),
            .other => |o| o.deinit(),
        }
    }

    pub fn fileName(self: SfsFile) []const u8 {
        return switch (self) {
            .regular => |r| r.name,
            .directory => |d| d.name,
            .symlink => |s| s.name,
            .other => |o| o.name,
        };
    }
    pub fn filePath(self: SfsFile, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .regular => |r| r.filePath(alloc),
            .directory => |d| d.filePath(alloc),
            .symlink => |s| s.filePath(alloc),
            .other => |o| o.filePath(alloc),
        };
    }

    pub const ExtractConfig = struct {
        /// The amount of cpu threads to use for decompresion
        threads: u16,
        /// Attempt to extract a symlink's target as well.
        /// Only works if the target is deeper in the directory tree.
        unbreak_sym: bool = false,
        /// Extract symlinks as their target file instead of as a symlink.
        deref_sym: bool = false,
        /// Verbose logging.
        verbose: bool = false,
        /// Location to verbose log. If null, uses stdout.
        log_writer: ?std.io.AnyWriter,

        pub fn init() !ExtractConfig {
            return .{
                .threads = @truncate(try std.Thread.getCpuCount()),
            };
        }

        fn log(self: ExtractConfig, comptime fmt: []const u8, args: anytype) void {
            std.fmt.format(
                self.log_writer orelse std.io.getStdOut().reader().any(),
                fmt,
                args,
            ) catch {};
        }
    };

    pub fn extract(self: SfsFile, config: ExtractConfig, path: []const u8) !void {
        return switch (self) {
            .regular => |r| r.extract(config, path),
            .directory => |d| d.extract(config, path),
            .symlink => |s| s.extract(config, path),
            .other => |o| o.extract(config, path),
        };
    }
};

pub const Regular = struct {
    rdr: *SfsReader,
    name: []const u8,
    parent_path: []const u8,
    inode: Inode,

    //TODO: data reader

    const Self = @This();

    pub fn init(rdr: *SfsReader, inode: Inode, name: []const u8, parent_path: []const u8) !Self {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        errdefer rdr.alloc.free(name_cpy);
        @memcpy(name_cpy, name);
        const parent_cpy = try rdr.alloc.alloc(u8, parent_path.len);
        errdefer rdr.alloc.free(parent_cpy);
        @memcpy(parent_cpy, name);
        //TODO: start data reader,
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Self) void {
        commonDeinit(self);
    }

    pub fn size(self: Self) u64 {
        return switch (self.inode.data) {
            .file => |f| f.size,
            .ext_file => |f| f.size,
            else => unreachable,
        };
    }

    pub fn filePath(self: Self, alloc: std.mem.Allocator) ![]const u8 {
        if (self.parent_path.len == 0) {
            const out = try alloc.alloc(u8, self.name.len);
            @memcpy(out, self.name);
            return out;
        }
        return std.mem.concat(alloc, u8, [3][]const u8{ self.parent_path, "/", self.name });
    }

    pub fn extract(self: Self, config: SfsFile.ExtractConfig, path: []const u8) !void {
        const extr_fil = try extractFile(self, config, path);
        defer extr_fil.close();
        //TODO: actual extraction.
    }
    fn extractThreaded(self: Self, config: SfsFile.ExtractConfig, path: []const u8, wg: *std.Thread.WaitGroup, errs: *std.ArrayList(anyerror)) void {
        defer wg.finish();
        const extr_fil = extractFile(self, config, path) catch |err| {
            errs.append(err) catch {};
        };
        defer extr_fil.close();
        //TODO: actual extraction.
    }
    fn extractFile(self: Self, config: SfsFile.ExtractConfig, path: []const u8) !std.fs.File {
        var path_is_dir = false;
        if (std.fs.cwd().statFile(path)) |s| {
            if (s.kind != .directory) return ExtractError.FileExists;
            path_is_dir = true;
        } else |err| {
            if (err != std.fs.File.OpenError.FileNotFound) {
                if (config.verbose)
                    config.log("file at {s} already exists\n", .{path});
                return err;
            }
        }
        const extr_path = if (path_is_dir)
            std.mem.concat(self.rdr.alloc, u8, [3][]const u8{ std.mem.trim(u8, path, "/"), "/", self.name }) catch |err| {
                if (config.verbose)
                    config.log("can't allocate memory: {}\n", .{err});
            }
        else
            path;
        defer if (extr_path.len != path.len) self.rdr.alloc.free(extr_path);
        if (config.verbose)
            config.lo("{s} extracting to {s}\n", .{ self.name, extr_path });
        return std.fs.cwd().createFile(extr_path, .{}) catch |err| {
            if (config.verbose)
                config.log("can't create {s}: {}\n", .{ extr_path, err });
        };
    }
};

pub const Dir = struct {
    rdr: *SfsReader,
    name: []const u8,
    parent_path: []const u8,
    inode: Inode,

    entries: std.StringArrayHashMap(dir.DirEntry),

    const Self = @This();

    pub fn init(rdr: *SfsReader, inode: Inode, name: []const u8, parent_path: []const u8) !Self {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        errdefer rdr.alloc.free(name_cpy);
        @memcpy(name_cpy, name);
        const parent_cpy = try rdr.alloc.alloc(u8, parent_path.len);
        errdefer rdr.alloc.free(parent_cpy);
        @memcpy(parent_cpy, name);
        var block: u32 = 0;
        var offset: u16 = 0;
        var size: u32 = 0;
        switch (inode.data) {
            .directory => |d| {
                block = d.block;
                offset = d.offset;
                size = d.size;
            },
            .ext_directory => |d| {
                block = d.block;
                offset = d.offset;
                size = d.size;
            },
            else => unreachable,
        }
        const offset_rdr = rdr.rdr.readerAt(rdr.super.dir_start + block);
        var meta_rdr: MetadataReader(@TypeOf(offset_rdr)) = try .init(
            rdr.alloc,
            rdr.super.compress,
            offset_rdr,
        );
        try meta_rdr.skip(offset);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .parent_path = parent_cpy,
            .inode = inode,
            .entries = try dir.readEntries(rdr.alloc, &meta_rdr, size),
        };
    }
    pub fn deinit(self: *Self) void {
        commonDeinit(self);
        for (self.entries.values()) |e| {
            e.deinit(self.rdr.alloc);
        }
        self.entries.deinit();
    }

    pub fn filePath(self: Self, alloc: std.mem.Allocator) ![]const u8 {
        if (self.parent_path.len == 0) {
            const out = try alloc.alloc(u8, self.name.len);
            @memcpy(out, self.name);
            return out;
        }
        return std.mem.concat(alloc, u8, [3][]const u8{ self.parent_path, "/", self.name });
    }

    const OpenError = error{
        NotFound,
    };

    pub fn open(self: Self, path: []const u8) !SfsFile {
        const fil_path = std.mem.trim(u8, path, "/");
        if (fil_path.len == 0) return .{ .directory = self };
        const sep_ind = std.mem.indexOf(u8, fil_path, "/") orelse fil_path.len;
        const fil_name = fil_path[0..sep_ind];
        const ent = self.entries.get(fil_name) orelse {
            return OpenError.NotFound;
        };
        if (sep_ind == fil_path.len) {
            return .initWDirEntry(self.rdr, ent);
        }
        if (ent.inode_type != .directory) return OpenError.NotFound;
        const fil: SfsFile = try .initWDirEntry(self.rdr, ent);
        return fil.directory.open(fil_path[sep_ind..]);
    }

    pub fn iterator(self: Self) DirIterator {
        return .{
            .rdr = self.rdr,
            .entries = self.entries.values(),
        };
    }
    pub fn nameIterator(self: Self) NameIterator {
        return .{
            .rdr = self.rdr,
            .entries = self.entries.values(),
        };
    }

    pub fn extract(self: Self, config: SfsFile.ExtractConfig, path: []const u8) !void {
        if (config.threads > 1) {
            const ext_path = self.extractPath(config, path) catch |err| {
                return err;
            };
            defer if (ext_path.len != path.len) self.rdr.alloc.free(ext_path);
            for (self.entries.keys()) |k| {
                const ent = self.entries.get(k) orelse unreachable;
                const fil_ext_path = std.mem.concat(self.rdr.alloc, u8, [3][]const u8{}) catch |err| {
                    if (config.verbose)
                        config.log("can't allocate memory: {}\n", .{err});
                    return err;
                };
                defer self.rdr.alloc.free(fil_ext_path);
                const fil: SfsFile = .fromDirEntry(self.rdr, ent, "") catch |err| {
                    if (config.verbose)
                        config.log("error getting {s}: {}\n", .{ ent.name, err });
                    return err;
                };
                defer fil.deinit();
                try fil.extract(config, fil_ext_path);
            }
        } else {
            const reg_files: std.ArrayList(struct { []const u8, dir.DirEntry }) = .init(self.rdr.alloc);
            defer reg_files.deinit();
            defer for (reg_files.items) |it| {
                self.rdr.alloc.free(it.@"0");
            };
            errdefer for (reg_files.items) |it| {
                it.@"1".deinit(self.rdr.alloc);
            };
            const errs: std.ArrayList(anyerror) = .init(self.rdr.alloc);
            defer errs.deinit();
            self.extractThreaded(config, path, reg_files, errs);
            if (errs.items.len > 0) {
                return errs.items[0];
            }
            const pool: std.Thread.Pool = undefined;
            try pool.init(.{
                .n_jobs = config.threads,
            });
            defer pool.deinit();
            const wg: std.Thread.WaitGroup = .{};
            for (reg_files.items) |*it| {
                const fil: SfsFile = .fromDirEntry(self.rdr, it.@"1", "") catch |err| {
                    if (config.verbose)
                        config.log("error extracting {s}: {}\n", .{ it.@"1".name, err });
                    return err;
                };
                //TODO: If certain config options are set, have the option of symlinks.
                pool.spawn(Regular.extractThreaded, .{ fil.regular, config, it.@"0", &wg, &errs });
                it.@"1".deinit(self.rdr.alloc);
            }
        }
    }
    fn extractThreaded(self: Self, config: SfsFile.ExtractConfig, path: []const u8, reg_files: *std.ArrayList(struct { []const u8, dir.DirEntry }), errs: *std.ArrayList(anyerror)) void {
        const ext_path = self.extractPath(config, path) catch |err| {
            errs.append(err) catch {};
            return;
        };
        defer if (ext_path.len != path.len) self.rdr.alloc.free(ext_path);
        for (self.entries.keys()) |k| {
            const ent = self.entries.get(k) orelse unreachable;
            const fil_ext_path = std.mem.concat(self.rdr.alloc, u8, [3][]const u8{ ext_path, "/", ent.name }) catch |err| {
                if (config.verbose)
                    config.log("can't allocate memory: {}\n", .{err});
                errs.append(err) catch {};
                return;
            };
            if (ent.inode_type == .file) { //TODO: Also add symlinks if certain config options are set.
                reg_files.append(.{ fil_ext_path, ent }) catch {};
                return;
            }
            defer self.rdr.free(fil_ext_path);
            const fil: SfsFile = .fromDirEntry(self.rdr, ent, "") catch |err| {
                if (config.verbose)
                    config.log("error extracting {s}: {}\n", .{ ent.name, err });
                errs.append(err) catch {};
                return;
            };
            defer fil.deinit();
            fil.extract(config, fil_ext_path) catch |err| {
                if (config.verbose)
                    config.log("error extracting {s}: {}\n", .{ ent.name, err });
                errs.append(err) catch {};
                return;
            };
        }
    }
    fn extractPath(self: Self, config: SfsFile.ExtractConfig, path: []const u8) ![]const u8 {
        var path_is_dir = false;
        if (std.fs.cwd().statFile(path)) |s| {
            if (s.kind != .directory) return ExtractError.FileExists;
            path_is_dir = true;
        } else |err| {
            if (err != std.fs.File.OpenError.FileNotFound) {
                if (config.verbose)
                    config.log("file at {s} already exists\n", .{path});
                return err;
            }
        }
        const extr_path = if (!path_is_dir)
            std.mem.concat(self.rdr.alloc, u8, [3][]const u8{ std.mem.trim(u8, path, "/"), "/", self.name }) catch |err| {
                if (config.verbose)
                    config.log("can't allocate memory: {}\n", .{err});
            }
        else
            path;
        if (!path_is_dir) {
            std.fs.cwd().makeDir(extr_path, .{}) catch |err| {
                if (config.verbose)
                    config.log("can't create {s}: {}\n", .{ extr_path, err });
                return err;
            };
        }
        return extr_path;
    }
};

pub const Sym = struct {
    rdr: *SfsReader,
    name: []const u8,
    parent_path: []const u8,
    inode: Inode,

    const Self = @This();

    pub fn init(rdr: *SfsReader, inode: Inode, name: []const u8, parent_path: []const u8) !Self {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        const parent_cpy = try rdr.alloc.alloc(u8, parent_path.len);
        @memcpy(parent_cpy, name);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Self) void {
        commonDeinit(self);
    }

    pub fn filePath(self: Self, alloc: std.mem.Allocator) ![]const u8 {
        if (self.parent_path.len == 0) {
            const out = try alloc.alloc(u8, self.name.len);
            @memcpy(out, self.name);
            return out;
        }
        return std.mem.concat(alloc, u8, [3][]const u8{ self.parent_path, "/", self.name });
    }

    pub fn extract(self: Self, config: SfsFile.ExtractConfig, path: []const u8) !void {}
    fn extractReal(self: Self, config: SfsFile.ExtractConfig, path: []const u8, reg_file_pool: *std.ArrayList(struct { []const u8, Regular })) !void {}
};

pub const Other = struct {
    rdr: *SfsReader,
    name: []const u8,
    parent_path: []const u8,
    inode: Inode,

    const Self = @This();

    pub fn init(rdr: *SfsReader, inode: Inode, name: []const u8, parent_path: []const u8) !Self {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        const parent_cpy = try rdr.alloc.alloc(u8, parent_path.len);
        @memcpy(parent_cpy, name);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Self) void {
        commonDeinit(self);
    }

    pub fn filePath(self: Self, alloc: std.mem.Allocator) ![]const u8 {
        if (self.parent_path.len == 0) {
            const out = try alloc.alloc(u8, self.name.len);
            @memcpy(out, self.name);
            return out;
        }
        return std.mem.concat(alloc, u8, [3][]const u8{ self.parent_path, "/", self.name });
    }

    pub fn extract(self: Self, config: SfsFile.ExtractConfig, path: []const u8) !void {}
    fn extractReal(self: Self, config: SfsFile.ExtractConfig, path: []const u8, reg_file_pool: *std.ArrayList(struct { []const u8, Regular })) !void {}
};

fn commonDeinit(self: anytype) void {
    self.inode.deinit();
    self.rdr.alloc.free(self.name);
    self.rdr.alloc.free(self.parent_path);
}

const DirIterator = struct {
    rdr: *SfsReader,
    entries: []dir.DirEntry,
    idx: usize = 0,

    /// Make sure to call deinit() on the returned SfsFile.
    pub fn next(self: *DirIterator) !?SfsFile {
        if (self.idx >= self.entries.len) return null;
        defer self.idx += 1;
        return .initWDirEntry(self.rdr, self.entries[self.idx]);
    }
};
const NameIterator = struct {
    rdr: *SfsReader,
    entries: []dir.DirEntry,
    idx: usize = 0,

    pub fn next(self: *DirIterator) ?[]const u8 {
        if (self.idx >= self.entries.len) return null;
        defer self.idx += 1;
        return self.entries[self.idx].name;
    }
};

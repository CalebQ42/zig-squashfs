const std = @import("std");
const builtin = @import("builtin");

const dir = @import("directory.zig");

const DirEntry = dir.Entry;
const Inode = @import("inode.zig");
const SfsReader = @import("reader.zig").SfsReader;
const ToReader = @import("reader/to_read.zig").ToRead;
const ExtractionOptions = @import("extract_options.zig");
const DataReader = @import("reader/data.zig").DataReader;
const Compression = @import("superblock.zig").Compression;
const MetadataReader = @import("reader/metadata.zig").MetadataReader;

pub fn File(comptime T: type) type {
    return struct {
        pub const FileError = error{
            NotRegular,
            NotDirectory,
            NotFound,
        };

        const Self = @This();

        rdr: *SfsReader(T),
        // parent: *File(T),

        inode: Inode,
        name: []const u8,

        /// Directory entries. Only populated on directories.
        entries: ?[]DirEntry = null,
        /// File reader. Only populated on regular files.
        data_reader: ?DataReader(T) = null,

        pub fn init(rdr: *SfsReader(T), inode: Inode, name: []const u8) !Self {
            const name_cpy: []u8 = try rdr.alloc.alloc(u8, name.len);
            @memcpy(name_cpy, name);
            var out = Self{
                .rdr = rdr,
                .inode = inode,
                .name = name_cpy,
            };
            switch (inode.data) {
                .dir => |d| {
                    var meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, &meta, d.size);
                },
                .ext_dir => |d| {
                    var meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, &meta, d.size);
                },
                .file => |f| {
                    out.data_reader = try .init(rdr, inode);
                    _ = f;
                    //TODO: fragments
                    // if (f.hasFragment()) {
                    //     try out.data_reader.?.addFragment(
                    //         try rdr.frag_table.get(f.frag_idx),
                    //         f.frag_offset,
                    //     );
                    // }
                },
                .ext_file => |f| {
                    out.data_reader = try .init(rdr, inode);
                    _ = f;
                    //TODO: Fragments
                    // if (f.hasFragment()) {
                    //     try out.data_reader.?.addFragment(
                    //         try rdr.frag_table.get(f.frag_idx),
                    //         f.frag_offset,
                    //     );
                    // }
                },
                else => {},
            }
            return out;
        }
        pub fn initFromRef(rdr: *SfsReader(T), ref: Inode.Ref, name: []const u8) !Self {
            var meta: MetadataReader(T) = .init(rdr.alloc, rdr.super.comp, rdr.rdr, ref.block + rdr.super.inode_start);
            try meta.skip(ref.offset);
            const inode: Inode = try .init(&meta, rdr.alloc, rdr.super.block_size);
            return .init(rdr, inode, name);
        }
        pub fn initFromEntry(rdr: *SfsReader(T), ent: DirEntry) !Self {
            var meta: MetadataReader(T) = .init(rdr.alloc, rdr.super.comp, rdr.rdr, ent.block + rdr.super.inode_start);
            try meta.skip(ent.offset);
            const inode: Inode = try .init(&meta, rdr.alloc, rdr.super.block_size);
            return .init(rdr, inode, ent.name);
        }
        pub fn deinit(self: *Self) void {
            self.rdr.alloc.free(self.name);
            self.inode.deinit(self.rdr.alloc);
            if (self.entries != null) {
                for (self.entries.?) |e| {
                    e.deinit(self.rdr.alloc);
                }
                self.rdr.alloc.free(self.entries.?);
            }
            if (self.data_reader != null) {
                self.data_reader.?.deinit();
            }
        }

        pub fn uid(self: Self) !u32 {
            return self.rdr.id_table.get(self.inode.hdr.uid_idx);
        }
        pub fn gid(self: Self) !u32 {
            return self.rdr.id_table.get(self.inode.hdr.uid_idx);
        }

        const Reader = std.io.GenericReader(*DataReader(T), anyerror, DataReader(T).read);

        pub fn read(self: *Self, buf: []u8) !usize {
            if (self.data_reader == null) return FileError.NotRegular;
            return self.data_reader.?.read(buf);
        }
        pub fn reader(self: *Self) !Reader {
            if (self.data_reader == null) return FileError.NotRegular;
            return self.data_reader.?.reader();
        }

        pub fn open(self: Self, path: []const u8) !Self {
            if (self.entries == null) return FileError.NotDirectory;
            if (path.len == 0) return self;
            const idx = std.mem.indexOf(u8, path, "/") orelse path.len;
            if (idx == 0) return self.open(path[1..]);
            const name = path[0..idx];
            for (self.entries.?) |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    var fil: Self = try .initFromEntry(self.rdr, e);
                    if (idx >= path.len - 1) return fil;
                    defer fil.deinit();
                    return fil.open(path[idx + 1 ..]);
                }
            }
            return FileError.NotFound;
        }
        pub fn iterate(self: Self) Iterator {
            return .{
                .rdr = self.rdr,
                .entries = self.entries.?,
            };
        }

        const Iterator = struct {
            rdr: *SfsReader(T),
            entries: []DirEntry,

            idx: u32 = 0,

            pub fn next(self: *Iterator) !?File(T) {
                if (self.idx >= self.entries.len) return null;
                const out = try Self.initFromEntry(self.rdr, self.entries[self.idx]);
                self.idx += 1;
                return out;
            }
            pub fn reset(self: *Iterator) void {
                self.idx = 0;
            }
        };

        const WaitGroup = std.Thread.WaitGroup;
        const Pool = std.Thread.Pool;
        const Mutex = std.Thread.Mutex;

        pub const ExtractError = error{FileExists};

        pub fn extract(self: *Self, op: ExtractionOptions, path: []const u8) !void {
            var wg: WaitGroup = .{};
            var pol: Pool = undefined;
            try pol.init(.{
                .n_jobs = op.thread_count,
                .allocator = self.rdr.alloc,
            });
            defer pol.deinit();
            var errs: std.ArrayList(anyerror) = .init(self.rdr.alloc);
            defer errs.deinit();
            try self.extractInode(op, &wg, &errs, &pol, self.inode, path);
            wg.wait();
            if (errs.items.len > 0) return errs.items[0];
        }
        fn extractInode(
            self: *Self,
            op: ExtractionOptions,
            wg: *WaitGroup,
            errs: *std.ArrayList(anyerror),
            pol: *Pool,
            inode: Inode,
            path: []const u8,
        ) !void {
            wg.start();
            defer wg.finish(); //TODO: When everthing is threaded, this will need to be handled by the threads, not here.
            switch (inode.hdr.type) {
                .file, .ext_file => {
                    var fil = try std.fs.cwd().createFile(path, .{});
                    defer fil.close();
                    var data: DataReader(T) = try .init(self.rdr, inode);
                    defer data.deinit();
                    try data.writeTo(fil); // TODO: Thread
                    const fil_uid = self.rdr.id_table.get(inode.hdr.uid_idx) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error getting uid {} from table: {}\n", .{ inode.hdr.uid_idx, err }) catch {};
                        }
                        return;
                    };
                    const fil_gid = self.rdr.id_table.get(inode.hdr.gid_idx) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error getting gid {} from table: {}\n", .{ inode.hdr.gid_idx, err }) catch {};
                        }
                        return;
                    };
                    fil.chmod(inode.hdr.perm) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error chmod {s}: {}\n", .{ path, err }) catch {};
                        }
                        return;
                    };
                    fil.chown(fil_uid, fil_gid) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error chmod {s}: {}\n", .{ path, err }) catch {};
                        }
                        return;
                    };
                    //TODO: update mtime.
                },
                .dir, .ext_dir => {
                    std.fs.cwd().makeDir(path) catch |err| {
                        if (err != std.fs.Dir.MakeError.PathAlreadyExists) {
                            return err;
                        }
                    };
                    var dir_block: u32 = 0;
                    var dir_offset: u16 = 0;
                    var dir_size: u32 = 0;
                    switch (inode.data) {
                        .dir => |d| {
                            dir_block = d.block;
                            dir_offset = d.offset;
                            dir_size = d.size;
                        },
                        .ext_dir => |d| {
                            dir_block = d.block;
                            dir_offset = d.offset;
                            dir_size = d.size;
                        },
                        else => unreachable,
                    }
                    var meta: MetadataReader(T) = .init(self.rdr.alloc, self.rdr.super.comp, self.rdr.rdr, dir_block + self.rdr.super.dir_start);
                    try meta.skip(dir_offset);
                    const entries = try dir.readDirectory(self.rdr.alloc, &meta, dir_size);
                    defer self.rdr.alloc.free(entries);
                    for (entries) |ent| {
                        defer ent.deinit(self.rdr.alloc);
                        var new_path: []u8 = undefined;
                        if (path[path.len - 1] == '/') {
                            new_path = self.rdr.alloc.alloc(u8, path.len + ent.name.len) catch |err| {
                                if (op.verbose) {
                                    std.fmt.format(op.verbose_logger, "error allocating memory: {}\n", .{err}) catch {};
                                }
                                errs.append(err) catch {};
                                continue;
                            };
                            @memcpy(new_path[0..path.len], path);
                            @memcpy(new_path[path.len..], ent.name);
                        } else {
                            new_path = self.rdr.alloc.alloc(u8, path.len + ent.name.len + 1) catch |err| {
                                if (op.verbose) {
                                    std.fmt.format(op.verbose_logger, "error allocating memory: {}\n", .{err}) catch {};
                                }
                                errs.append(err) catch {};
                                continue;
                            };
                            @memcpy(new_path[0..path.len], path);
                            new_path[path.len] = '/';
                            @memcpy(new_path[path.len + 1 ..], ent.name);
                        }
                        defer self.rdr.alloc.free(new_path);

                        meta = .init(self.rdr.alloc, self.rdr.super.comp, self.rdr.rdr, ent.block + self.rdr.super.inode_start);
                        meta.skip(ent.offset) catch |err| {
                            if (op.verbose) {
                                std.fmt.format(op.verbose_logger, "error reading inode: {}\n", .{err}) catch {};
                            }
                            errs.append(err) catch {};
                            continue;
                        };
                        const new_inode = Inode.init(&meta, self.rdr.alloc, self.rdr.super.block_size) catch |err| {
                            if (op.verbose) {
                                std.fmt.format(op.verbose_logger, "error reading inode: {}\n", .{err}) catch {};
                            }
                            errs.append(err) catch {};
                            continue;
                        };
                        defer new_inode.deinit(self.rdr.alloc);
                        self.extractInode(op, wg, errs, pol, new_inode, new_path) catch |err| {
                            if (op.verbose) {
                                std.fmt.format(op.verbose_logger, "error extracting {s}: {}\n", .{ new_path, err }) catch {};
                            }
                            errs.append(err) catch {};
                            continue;
                        };
                    }

                    var fil = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error openning {s} to set permissions: {}\n", .{ path, err }) catch {};
                        }
                        return;
                    };
                    const fil_uid = self.rdr.id_table.get(inode.hdr.uid_idx) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error getting uid {} from table: {}\n", .{ inode.hdr.uid_idx, err }) catch {};
                        }
                        return;
                    };
                    const fil_gid = self.rdr.id_table.get(inode.hdr.gid_idx) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error getting gid {} from table: {}\n", .{ inode.hdr.gid_idx, err }) catch {};
                        }
                        return;
                    };
                    fil.chmod(inode.hdr.perm) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error chmod {s}: {}\n", .{ path, err }) catch {};
                        }
                        return;
                    };
                    fil.chown(fil_uid, fil_gid) catch |err| {
                        if (op.verbose) {
                            std.fmt.format(op.verbose_logger, "error chmod {s}: {}\n", .{ path, err }) catch {};
                        }
                        return;
                    };
                },
                // .symlink, .ext_symlink => {},
                else => {
                    std.debug.print("TODO: {}\n", .{inode.hdr.type});
                },
            }
        }
    };
}

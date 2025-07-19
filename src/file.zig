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
                    out.data_reader = try .init(
                        rdr.alloc,
                        rdr.rdr,
                        rdr.super.comp,
                        f.block,
                        f.size,
                        f.block_sizes,
                        rdr.super.block_size,
                    );
                    if (f.hasFragment()) {
                        try out.data_reader.?.addFragment(
                            try rdr.frag_table.get(f.frag_idx),
                            f.frag_offset,
                        );
                    }
                },
                .ext_file => |f| {
                    out.data_reader = try .init(
                        rdr.alloc,
                        rdr.rdr,
                        rdr.super.comp,
                        f.block,
                        f.size,
                        f.block_sizes,
                        rdr.super.block_size,
                    );
                    if (f.hasFragment()) {
                        try out.data_reader.?.addFragment(
                            try rdr.frag_table.get(f.frag_idx),
                            f.frag_offset,
                        );
                    }
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
        pub fn deinit(self: Self) void {
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

        pub fn extract(self: Self, op: ExtractionOptions, path: []const u8) !void {
            var exists = true;
            var stat: ?std.fs.File.Stat = null;
            if (std.fs.cwd().statFile(path)) |s| {
                stat = s;
            } else |err| {
                if (err == std.fs.File.OpenError.FileNotFound) {
                    exists = false;
                } else {
                    return err;
                }
            }
            switch (self.inode.hdr.type) {
                .dir, .ext_dir => {
                    if (exists and stat.?.kind != .directory) {
                        return ExtractError.FileExists;
                    } else if (!exists) {
                        try std.fs.cwd().makeDir(path);
                    }
                },
                else => if (exists) return ExtractError.FileExists,
            }
            var wg: WaitGroup = .{};
            var pol: Pool = undefined;
            try pol.init(.{
                .n_jobs = op.thread_count,
                .allocator = self.rdr.alloc,
            });
            defer pol.deinit();
            var errs: std.ArrayList(anyerror) = .init(self.rdr.alloc);
            defer errs.deinit();
            try self.extractReal(op, path, &errs, &wg, &pol, true);
            wg.wait();
            if (errs.items.len > 0) return errs.items[0];
        }
        fn extractReal(
            self: Self,
            op: ExtractionOptions,
            path: []const u8,
            errs: *std.ArrayList(anyerror),
            wg: *WaitGroup,
            pol: *Pool,
            first: bool,
        ) !void {
            if (errs.items.len > 0) return;
            if (op.verbose) {
                std.fmt.format(op.verbose_logger, "extracting inode {} \"{s}\" to {s}...\n", .{ self.inode.hdr.num, self.name, path }) catch {};
            }
            return switch (self.inode.hdr.type) {
                .dir, .ext_dir => {
                    wg.start();
                    errdefer wg.finish();
                    for (self.entries.?) |ent| {
                        var fil = initFromEntry(self.rdr, ent) catch |err| {
                            continue;
                        };
                    }
                },
                .file, .ext_file => {
                    wg.start();
                    errdefer wg.finish();
                    var ext_fil = try std.fs.cwd().createFile(path, .{});
                    errdefer ext_fil.close();
                    var fil_errs: std.ArrayList(anyerror) = .init(self.rdr.alloc);
                    errdefer fil_errs.deinit();
                    @constCast(&self.data_reader.?).setPool(pol);
                    try self.data_reader.?.writeToNoBlock(errs, ext_fil, filExtractFinish, .{
                        self,
                        op,
                        path,
                        &fil_errs,
                        errs,
                        wg,
                        ext_fil,
                        first,
                    });
                },
                .symlink, .ext_symlink => {},
                .block_dev, .ext_block_dev, .char_dev, .ext_char_dev, .fifo, .ext_fifo => {
                    //TODO: check for all oses that accept unix permissions.
                },
                else => {
                    if (op.verbose) {
                        std.fmt.format(
                            op.verbose_logger,
                            "inode {} \"{s}\" is a socket file. Ignoring.\n",
                            .{ self.inode.hdr.num, path },
                        ) catch {};
                    }
                },
            };
        }
        fn filExtractFinish(
            self: Self,
            op: ExtractionOptions,
            path: []const u8,
            fil_errs: *std.ArrayList(anyerror),
            errs: *std.ArrayList(anyerror),
            wg: *WaitGroup,
            fil: std.fs.File,
            first: bool,
        ) void {
            defer wg.finish();
            defer fil.close();
            defer if (!first) self.deinit();
            if (fil_errs.items.len > 0) {
                if (op.verbose) {
                    for (fil_errs.items) |err| {
                        std.fmt.format(
                            op.verbose_logger,
                            "error extracting inode {} to \"{s}\": {}\n",
                            .{ self.inode.hdr.num, path, err },
                        ) catch {};
                    }
                }
                errs.append(fil_errs.items[0]) catch {};
                return;
            }
            if (op.ignore_permissions) return;
            const fil_uid = self.uid() catch |err| {
                std.fmt.format(
                    op.verbose_logger,
                    "error getting uid for inode {} \"{s}\": {}\n",
                    .{ self.inode.hdr.num, path, err },
                ) catch {};
                return;
            };
            const fil_gid = self.gid() catch |err| {
                std.fmt.format(
                    op.verbose_logger,
                    "error getting gid for inode {} \"{s}\": {}\n",
                    .{ self.inode.hdr.num, path, err },
                ) catch {};
                return;
            };
            fil.chmod(self.inode.hdr.perm) catch |err| {
                std.fmt.format(
                    op.verbose_logger,
                    "error setting permissions for inode {} \"{s}\": {}\n",
                    .{ self.inode.hdr.num, path, err },
                ) catch {};
                return;
            };
            fil.chown(fil_uid, fil_gid) catch |err| {
                std.fmt.format(
                    op.verbose_logger,
                    "error setting owner for inode {} \"{s}\": {}\n",
                    .{ self.inode.hdr.num, path, err },
                ) catch {};
                return;
            };
        }
    };
}

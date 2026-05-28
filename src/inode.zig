//! A file-system object. Represents a File or directory.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;

const DirEntry = @import("dir_entry.zig");
const ExtractionOptions = @import("options.zig");
const FragEntry = @import("frag.zig").FragEntry;
const DirTypes = @import("inode_data/dir.zig");
const FileTypes = @import("inode_data/file.zig");
const MiscTypes = @import("inode_data/misc.zig");
const LookupTable = @import("lookup_table.zig");
const DataExtract = @import("util/data_extract.zig");
const DecompCache = @import("util/decomp_cache.zig");
const MetadataReader = @import("util/metadata.zig");

pub const Ref = packed struct(u64) {
    block_offset: u16,
    block_start: u32,
    _: u16,
};

pub const Type = enum(u16) {
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

pub const Data = union(Type) {
    dir: DirTypes.Dir,
    file: FileTypes.File,
    symlink: MiscTypes.Symlink,
    block_dev: MiscTypes.Dev,
    char_dev: MiscTypes.Dev,
    fifo: MiscTypes.IPC,
    socket: MiscTypes.IPC,
    ext_dir: DirTypes.ExtDir,
    ext_file: FileTypes.ExtFile,
    ext_symlink: MiscTypes.ExtSymlink,
    ext_block_dev: MiscTypes.ExtDev,
    ext_char_dev: MiscTypes.ExtDev,
    ext_fifo: MiscTypes.ExtIPC,
    ext_socket: MiscTypes.ExtIPC,
};

pub const Header = packed struct {
    inode_type: Type,
    permissions: u16,
    uid_idx: u16,
    gid_idx: u16,
    mod_time: u32,
    num: u32,
};

pub const Error = error{
    NotDirectory,
};

const Inode = @This();

hdr: Header,
data: Data,

pub fn fromRef(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, inode_start: u64, block_size: u32, ref: Ref) !Inode {
    var meta: MetadataReader = .init(io, cache, ref.block_start + inode_start);
    defer meta.deinit();
    try meta.interface.discardAll(ref.block_offset);
    return fromReader(alloc, &meta.interface, block_size);
}
pub fn fromReader(alloc: std.mem.Allocator, rdr: *Reader, block_size: u32) !Inode {
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
pub fn copy(alloc: std.mem.Allocator, from: Inode) !Inode {
    var new = from;
    switch (from.data) {
        .file => |f| {
            new.data.file.block_sizes = try alloc.alloc(FileTypes.BlockSize, f.block_sizes.len);
            @memcpy(new.data.file.block_sizes, f.block_sizes);
        },
        .ext_file => |f| {
            new.data.ext_file.block_sizes = try alloc.alloc(FileTypes.BlockSize, f.block_sizes.len);
            @memcpy(new.data.ext_file.block_sizes, f.block_sizes);
        },
        .symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            new.data.symlink.target = new_target;
        },
        .ext_symlink => |s| {
            const new_target = try alloc.alloc(u8, s.target.len);
            @memcpy(new_target, s.target);
            new.data.ext_symlink.target = new_target;
        },
        else => {},
    }
    return new;
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

pub fn readDirectory(self: Inode, alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64) ![]DirEntry {
    return switch (self.data) {
        .dir => |d| readDirectoryFromData(alloc, io, cache, dir_start, d),
        .ext_dir => |d| readDirectoryFromData(alloc, io, cache, dir_start, d),
        else => Error.NotDirectory,
    };
}
fn readDirectoryFromData(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, dir_start: u64, d: anytype) ![]DirEntry {
    var meta: MetadataReader = .init(io, cache, dir_start + d.block_start);
    defer meta.deinit();
    try meta.interface.discardAll(d.block_offset);

    return DirEntry.readEntries(alloc, &meta.interface, d.size);
}

// Extraction

pub const ExtractionError = error{ SetXattr, Mknod, Canceled } || DirEntry.Error || Io.Dir.CreateFileAtomicError || DataExtract.Error || Io.File.Atomic.LinkError ||
    Io.Dir.SymLinkError;

const ExtractReturn = struct {
    path: []const u8,
    inode: Inode,

    fn deinit(self: ExtractReturn, alloc: std.mem.Allocator) void {
        self.inode.deinit(alloc);
        alloc.free(self.path);
    }
    fn setMetadata(self: ExtractReturn, alloc: std.mem.Allocator, io: Io, cache: *DecompCache, id_start: u64, xattr_start: u64, options: ExtractionOptions) !void {
        defer self.deinit(alloc);
        if (options.ignore_permissions and options.ignore_xattr) return;

        var fil = try Io.Dir.cwd().openFile(io, self.path, .{});
        defer fil.close(io);

        if (!options.ignore_permissions) {
            try fil.setTimestamps(io, .{ .modify_timestamp = .{
                .new = .{ .nanoseconds = self.inode.hdr.mod_time * std.time.ns_per_s },
            } });
            try fil.setPermissions(io, @enumFromInt(self.inode.hdr.permissions));
            try fil.setOwner(
                io,
                try LookupTable.lookup(u16, io, cache, id_start, self.inode.hdr.uid_idx),
                try LookupTable.lookup(u16, io, cache, id_start, self.inode.hdr.gid_idx),
            );
        }
        if (options.ignore_xattr or @hasField(std.os, "linux")) return;
        const xattr_idx: u32 = switch (self.inode.data) {
            .ext_dir => |d| d.xattr_idx,
            .ext_file => |f| f.xattr_idx,
            .ext_symlink => |s| s.xattr_idx,
            .ext_block_dev, .ext_char_dev => |d| d.xattr_idx,
            .ext_fifo, .ext_socket => |i| i.xattr_idx,
            else => return,
        };
        if (xattr_idx == 0xFFFFFFFF) return;
        const xattrs = try LookupTable.xattrLookup(alloc, io, cache, xattr_start, xattr_idx);
        defer {
            for (xattrs) |kv|
                kv.deinit(alloc);
            alloc.free(xattrs);
        }

        for (xattrs) |kv| {
            const res = std.os.linux.fsetxattr(fil.handle, kv.key.ptr, kv.value.ptr, kv.value.len, 0);
            if (res != 0)
                return ExtractionError.SetXattr;
        }
    }
};
const ExtractUnion = union { ret: ExtractionError!ExtractReturn };

pub fn extract(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    cache: *DecompCache,
    dir_start: u64,
    inode_start: u64,
    frag_start: u64,
    block_size: u32,
    id_start: u64,
    xattr_start: u64,
    ext_loc: []const u8,
    options: ExtractionOptions,
) !void {
    const path = std.mem.trimEnd(u8, ext_loc, "/");

    var sel_buf: [5]ExtractUnion = undefined;
    var sel: Io.Select(ExtractUnion) = .init(io, &sel_buf);
    defer sel.cancelDiscard();

    var meta_loop = io.async(metadataLoop, .{ alloc, io, cache, id_start, xattr_start, &sel, options });

    sel.async(.ret, extractReal, .{ self, alloc, io, cache, dir_start, inode_start, frag_start, block_size, &sel, path, true });

    try meta_loop.await(io);
}
fn extractReal(
    self: Inode,
    alloc: std.mem.Allocator,
    io: Io,
    cache: *DecompCache,
    dir_start: u64,
    inode_start: u64,
    frag_start: u64,
    block_size: u32,
    master_sel: *Io.Select(ExtractUnion),
    path: []const u8,
    origin: bool,
) ExtractionError!ExtractReturn {
    errdefer if (!origin) {
        self.deinit(alloc);
        alloc.free(path);
    };
    switch (self.hdr.inode_type) {
        .dir, .ext_dir => {
            const entries = self.readDirectory(alloc, io, cache, dir_start) catch |err| switch (err) {
                error.NotDirectory => unreachable,
                else => |e| return e,
            };
            defer {
                for (entries) |entry|
                    entry.deinit(alloc);
                alloc.free(entries);
            }

            var sel_buf: [5]ExtractUnion = undefined;
            var sel: Io.Select(ExtractUnion) = .init(io, &sel_buf);
            defer sel.cancelDiscard();

            var dir_loop = io.async(dirLoop, .{ alloc, io, &sel, master_sel });

            for (entries) |entry| {
                var meta: MetadataReader = .init(io, cache, inode_start + entry.block_start);
                defer meta.deinit();
                try meta.interface.discardAll(entry.block_offset);

                var new_inode: Inode = try .fromReader(alloc, &meta.interface, block_size);
                errdefer new_inode.deinit(alloc);

                const new_path = try std.mem.concat(alloc, u8, &.{ path, "/", entry.name });
                errdefer alloc.free(new_path);

                sel.async(.ret, extractReal, .{ new_inode, alloc, io, cache, dir_start, inode_start, frag_start, block_size, master_sel, new_path, false });
            }

            try dir_loop.await(io);
        },
        .file, .ext_file => {
            var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{});
            defer atomic.deinit(io);

            var data: DataExtract = undefined;
            var frag_offset: ?u64 = null;
            switch (self.data) {
                .file => |f| {
                    data = .init(cache.decomp, cache.map, block_size, f.block_start, f.size, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF) {
                        const entry: FragEntry = try LookupTable.lookup(FragEntry, io, cache, frag_start, f.frag_idx);
                        if (entry.size.uncompressed) {
                            data.addFrag(cache.map.memory[entry.start..][0..entry.size.size], f.frag_offset);
                        } else {
                            frag_offset = entry.start;
                            const block = try cache.checkoutBlock(io, entry.start, entry.size.size, block_size);
                            data.addFrag(block, f.frag_offset);
                        }
                    }
                },
                .ext_file => |f| {
                    data = .init(cache.decomp, cache.map, block_size, f.block_start, f.size, f.block_sizes);
                    if (f.frag_idx != 0xFFFFFFFF) {
                        const entry: FragEntry = try LookupTable.lookup(FragEntry, io, cache, frag_start, f.frag_idx);
                        if (entry.size.uncompressed) {
                            data.addFrag(cache.map.memory[entry.start..][0..entry.size.size], f.frag_offset);
                        } else {
                            frag_offset = entry.start;
                            const block = try cache.checkoutBlock(io, entry.start, entry.size.size, block_size);
                            data.addFrag(block, f.frag_offset);
                        }
                    }
                },
                else => unreachable,
            }
            defer if (frag_offset != null) cache.checkinBlock(io, frag_offset.?);

            try data.asyncExtract(alloc, io, atomic.file);

            try atomic.link(io);
        },
        .symlink, .ext_symlink => {
            const target = switch (self.data) {
                .symlink => |s| s.target,
                .ext_symlink => |s| s.target,
                else => unreachable,
            };
            try Io.Dir.cwd().symLink(io, target, path, .{});
        },
        else => {
            var dev: u32 = 0;
            var mode: u32 = undefined;

            const DT = std.os.linux.DT;

            switch (self.data) {
                .block_dev => |d| {
                    mode = DT.BLK;
                    dev = d.dev;
                },
                .ext_block_dev => |d| {
                    mode = DT.BLK;
                    dev = d.dev;
                },
                .char_dev => |d| {
                    mode = DT.CHR;
                    dev = d.dev;
                },
                .ext_char_dev => |d| {
                    mode = DT.CHR;
                    dev = d.dev;
                },
                .fifo, .ext_fifo => mode = DT.FIFO,
                .socket, .ext_socket => mode = DT.SOCK,
                else => unreachable,
            }

            const sentinel_path = try std.mem.concatWithSentinel(alloc, u8, &.{path}, 0);
            defer alloc.free(sentinel_path);
            const res = std.os.linux.mknod(sentinel_path, mode, dev);
            if (res != 0)
                return ExtractionError.Mknod;
        },
    }

    return .{
        .path = path,
        .inode = self,
    };
}
fn metadataLoop(alloc: std.mem.Allocator, io: Io, cache: *DecompCache, id_start: u64, xattr_start: u64, sel: *Io.Select(ExtractUnion), options: ExtractionOptions) !void {
    defer {
        while (sel.cancel()) |ret| {
            const res = ret.ret catch continue;
            res.deinit(alloc);
        }
    }
    while (sel.group.token.load(.unordered) != null) {
        const ret = try sel.await();

        const res = try ret.ret;

        try res.setMetadata(alloc, io, cache, id_start, xattr_start, options);
    }
}
fn dirLoop(alloc: std.mem.Allocator, io: Io, dir_sel: *Io.Select(ExtractUnion), master_sel: *Io.Select(ExtractUnion)) ExtractionError!void {
    while (dir_sel.group.token.load(.unordered) != null) {
        const ret = try dir_sel.await();
        master_sel.queue.putOne(io, ret) catch |err| switch (err) {
            error.Closed => {
                const res = try ret.ret;
                res.deinit(alloc);
            },
            else => |e| return e,
        };
    }
}

//! A squashfs archive read from a file.
//! Can be used to directly access File's contents or extract to the filesystem.

const std = @import("std");
const File = std.fs.File;
const builtin = @import("builtin");

const Decomp = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const InodeRef = Inode.Ref;
const BlockSize = @import("inode_data/file.zig").BlockSize;
const SfsFile = @import("file.zig");
const Superblock = @import("super.zig").Superblock;
const Tables = @import("tables.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const XattrTable = @import("xattr.zig");

const config = if (builtin.is_test) .{
    .use_zig_decomp = builtin.link_libc != true,
    .allow_lzo = false,
} else @import("config");

const Archive = @This();

alloc: std.mem.Allocator,

fil: OffsetFile,
decomp: Decomp.DecompFn,

super: Superblock,

tables: ?Tables = null,

/// Default settings using std.Thread.getCpuCount() threads and the minimum of 4gb or half of system memory for memory usage.
pub fn init(alloc: std.mem.Allocator, fil: File, offset: u64) !Archive {
    var super: Superblock = undefined;
    const red = try fil.pread(@ptrCast(&super), offset);
    std.debug.assert(red == @sizeOf(Superblock));
    try super.validate();
    const off_fil: OffsetFile = .init(fil, offset);
    const decomp: Decomp.DecompFn = switch (super.compression) {
        .gzip => Decomp.gzipDecompress,
        .lzma => Decomp.lzmaDecompress,
        .xz => Decomp.xzDecompress,
        .zstd => Decomp.zstdDecompress,
        .lz4 => if (!config.use_zig_decomp) Decomp.cLz4 else return error.Lz4Unsupported,
        .lzo => if (!config.use_zig_decomp and config.allow_lzo) Decomp.lzoDecompress else return error.LzoUnsupported,
    };
    return .{
        .alloc = alloc,
        .fil = off_fil,
        .decomp = decomp,
        .super = super,
    };
}
pub fn deinit(self: *Archive) void {
    if (self.tables != null)
        self.tables.?.deinit();
}

pub fn inode(self: *Archive, alloc: std.mem.Allocator, num: u32) !Inode {
    if (self.tables == null)
        self.tables = try .init(alloc, self);
    const ref = try self.export_table.get(num - 1);
    var rdr = try self.fil.readerAt(ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, &self.decomp);
    try meta.interface.discardAll(ref.block_offset);
    return try .read(alloc, &meta.interface, self.super.block_size);
}

pub fn root(self: *Archive, alloc: std.mem.Allocator) !SfsFile {
    if (self.tables == null)
        self.tables = try .init(alloc, self);
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(alloc, &meta.interface, self.super.block_size);
    return .init(self, in, "");
}

pub fn open(self: *Archive, alloc: std.mem.Allocator, path: []const u8) !SfsFile {
    if (self.tables == null)
        self.tables = try .init(alloc, self);
    var root_fil = try self.root(alloc);
    defer if (!SfsFile.pathIsSelf(path)) root_fil.deinit();
    return root_fil.open(path);
}

pub fn extract(self: Archive, alloc: std.mem.Allocator, path: []const u8, options: ExtractionOptions) !void {
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(self.alloc, &meta.interface, self.super.block_size);
    try in.extractTo(alloc, self, path, options);
}

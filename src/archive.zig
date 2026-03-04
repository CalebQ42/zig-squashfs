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
const Table = @import("table.zig").Table;
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const XattrTable = @import("xattr.zig");

const config = if (builtin.is_test) .{
    .use_c_libs = true,
    .allow_lzo = false,
} else @import("config");

/// Information about a fragment section. Multiple fragments are contained in the block described by a single FragEntry.
/// The offset into the block and fragment size is stored in the file's inode.
pub const FragEntry = packed struct {
    start: u64,
    size: BlockSize,
    _: u32,
};

const Archive = @This();

alloc: std.mem.Allocator,

fil: OffsetFile,
decomp: Decomp.DecompFn,

super: Superblock,

frag_table: Table(FragEntry),
id_table: Table(u16),
export_table: Table(InodeRef),
xattr_table: XattrTable,

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
        .lz4 => if (config.use_c_libs) Decomp.cLz4 else return error.Lz4Unsupported,
        .lzo => if (config.use_c_libs and config.allow_lzo) Decomp.lzoDecompress else return error.LzoUnsupported,
    };
    return .{
        .alloc = alloc,
        .fil = off_fil,
        .decomp = decomp,
        .super = super,
        .frag_table = try .init(alloc, off_fil, decomp, super.frag_start, super.frag_count),
        .id_table = try .init(alloc, off_fil, decomp, super.id_start, super.id_count),
        .export_table = try .init(alloc, off_fil, decomp, super.export_start, super.inode_count),
        .xattr_table = try .init(alloc, off_fil, decomp, super.xattr_start),
    };
}
pub fn deinit(self: *Archive) void {
    self.frag_table.deinit();
    self.export_table.deinit();
    self.id_table.deinit();
}

pub fn inode(self: *Archive, alloc: std.mem.Allocator, num: u32) !Inode {
    const ref = try self.export_table.get(num - 1);
    var rdr = try self.fil.readerAt(ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, &self.decomp);
    try meta.interface.discardAll(ref.block_offset);
    return try .read(alloc, &meta.interface, self.super.block_size);
}

pub fn root(self: *Archive, alloc: std.mem.Allocator) !SfsFile {
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(alloc, &meta.interface, self.super.block_size);
    return .init(self, in, "");
}

pub fn open(self: *Archive, alloc: std.mem.Allocator, path: []const u8) !SfsFile {
    var root_fil = try self.root(alloc);
    defer if (!SfsFile.pathIsSelf(path)) root_fil.deinit();
    return root_fil.open(path);
}

pub fn extract(self: *Archive, alloc: std.mem.Allocator, path: []const u8, options: ExtractionOptions) !void {
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.alloc, &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(self.alloc, &meta.interface, self.super.block_size);
    try in.extractTo(alloc, self, path, options);
}

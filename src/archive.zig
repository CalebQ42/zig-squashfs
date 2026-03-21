//! A squashfs archive read from a file.
//! Can be used to directly access File's contents or extract to the filesystem.

const std = @import("std");
const File = std.fs.File;
const builtin = @import("builtin");

const config = @import("config");

const cDecomp = @import("decomp/misc_c.zig");
const Decomp = @import("decomp/zig_decomp.zig");
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

const Archive = @This();

alloc: std.mem.Allocator,

fil: OffsetFile,

super: Superblock,

tables: ?Tables = null,

decomp: if (config.use_zig_decomp) Decomp.DecompFn else union(enum) {
    gzip: @import("decomp/gzip.zig"),
    lzma: @import("decomp/lzma.zig"),
    lzo: void,
    xz: @import("decomp/lzma.zig"),
    lz4: void,
    zstd: @import("decomp/zstd.zig"),

    pub fn decomp(self: @This(), in: []u8, out: []u8) !usize {
        return switch (self) {
            .gzip => |*g| g.decompress(in, out),
            .zstd => |*z| z.decompress(in, out),
            .lzma, .xz => |*d| d.decompress(in, out),
            .lz4 => cDecomp.lz4(in, out),
            .lzo => cDecomp.lzo(in, out),
        };
    }
},

/// Default settings using std.Thread.getCpuCount() threads and the minimum of 4gb or half of system memory for memory usage.
pub fn init(alloc: std.mem.Allocator, fil: File, offset: u64) !Archive {
    var super: Superblock = undefined;
    const red = try fil.pread(@ptrCast(&super), offset);
    std.debug.assert(red == @sizeOf(Superblock));
    try super.validate();
    const off_fil: OffsetFile = .init(fil, offset);
    return .{
        .alloc = alloc,
        .fil = off_fil,
        .decomp = if (config.use_zig_decomp)
            switch (super.compression) {
                .lz4 => return error.Lz4Unsupported,
                .lzo => return error.LzoUnsupported,
                .gzip => Decomp.gzip,
                .lzma => Decomp.lzma,
                .xz => Decomp.xz,
                .zstd => Decomp.zstd,
            }
        else switch (super.compression) {
            .gzip => .{ .gzip = .init(alloc) },
            .zstd => .{ .zstd = .init(alloc) },
            .xz => .{ .xz = .init(alloc, true) },
            .lzma => .{ .lzma = .init(alloc, false) },
            .lzo => .{ .lzo = .{} },
            .lz4 => .{ .lz4 = .{} },
        },
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

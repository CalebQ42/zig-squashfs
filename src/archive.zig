const std = @import("std");
const Io = std.Io;

const ExtractionOptions = @import("options.zig");
const File = @import("file.zig");
const Inode = @import("inode.zig");
const LookupTable = @import("lookup_table.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const Utils = @import("util/misc.zig");
const OffsetFile = @import("util/offset_file.zig");

const Archive = @This();

file: OffsetFile,
super: Superblock,

stateless_decomp: Decompressor,

pub fn init(io: Io, file: std.Io.File, offset: u64) !Archive {
    var rdr = file.reader(io, &[0]u8{});
    try rdr.seekTo(offset);
    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    return .{
        .file = .init(file, offset),
        .super = super,

        .stateless_decomp = switch (super.compression) {
            .gzip => @import("decomp/zlib.zig").stateless_decompressor,
            .lzma => @import("decomp/lzma.zig").stateless_decompressor,
            .lzo => return error.LzoUnsupported,
            .xz => @import("decomp/xz.zig").stateless_decompressor,
            .lz4 => return error.Lz4Unsupported,
            .zstd => @import("decomp/zstd.zig").stateless_decompressor,
        },
    };
}

/// The root folder of the Archive. Used to open other Files.
pub fn root(self: Archive, alloc: std.mem.Allocator, io: Io) !File {
    const root_inode = try Utils.inodeFromRef(
        alloc,
        io,
        self.file,
        &self.stateless_decomp,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    return .init(alloc, root_inode, "");
}
/// Opens a File within the archive.
pub fn open(self: Archive, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    const root_file = try self.root(alloc, io);
    const path = std.mem.trim(u8, filepath, "/");
    if (Utils.pathIsSelf(path))
        return root_file;
    defer root_file.deinit();
    return root_file.open(alloc, io, filepath);
}
/// Extract the entire archive contents to the given directory.
pub fn extract(self: Archive, alloc: std.mem.Allocator, io: Io, extract_dir: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = extract_dir;
    _ = options;
    return error.TODO;
}

/// Returns the inode with the given inode number.
/// Requires that the archive is exportable (has an export lookup table).
pub fn inode(self: Archive, alloc: std.mem.Allocator, io: Io, num: u32) !Inode {
    if (!self.super.flags.exportable)
        return error.NotExportable;
    const ref = try LookupTable.lookupValue(Inode.Ref, alloc, io, &self.stateless_decomp, self.file, self.super.export_start, num + 1);
    return Utils.inodeFromRef(
        alloc,
        io,
        self.file,
        &self.stateless_decomp,
        self.super.inode_start,
        self.super.block_size,
        ref,
    );
}

// Superblock

const SQUASHFS_MAGIC: u32 = std.mem.readInt(u32, "hsqs", .little);

const SuperblockError = error{
    InvalidMagic,
    InvalidBlockLog,
    InvalidVersion,
    InvalidCheck,
};

/// A squashfs Superblock
pub const Superblock = packed struct(u768) {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: enum(u16) {
        gzip = 1,
        lzma,
        lzo,
        xz,
        lz4,
        zstd,
    },
    block_log: u16,
    flags: packed struct {
        inode_uncompressed: bool,
        data_uncompressed: bool,
        check: bool,
        frag_uncompressed: bool,
        fragment_never: bool,
        fragment_always: bool,
        duplicates: bool,
        exportable: bool,
        xattr_uncompressed: bool,
        xattr_never: bool,
        compression_options: bool,
        ids_uncompressed: bool,
        _: u4,
    },
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_ref: Inode.Ref,
    size: u64,
    id_start: u64,
    xattr_start: u64,
    inode_start: u64,
    dir_start: u64,
    frag_start: u64,
    export_start: u64,

    /// Validate the Superblock. If an error is returned, it's likely the archive is corrupted or not a squashfs archive.
    pub fn validate(self: Superblock) !void {
        if (self.magic != SQUASHFS_MAGIC)
            return SuperblockError.InvalidMagic;
        if (self.flags.check)
            return SuperblockError.InvalidCheck;
        if (self.ver_maj != 4 or self.ver_min != 0)
            return SuperblockError.InvalidVersion;
        if (std.math.log2(self.block_size) != self.block_log)
            return SuperblockError.InvalidBlockLog;
    }
};

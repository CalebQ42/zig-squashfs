const std = @import("std");

const DecompTypes = @import("decomp/types.zig");
const Decompressor = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const File = @import("file.zig");
const Inode = @import("inode.zig");
const BlockSize = @import("inode/file.zig").BlockSize;
const LookupTable = @import("lookup_table.zig");
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");
const Utils = @import("util/utils.zig");

pub const Error = error{
    BadMagic,
    BadBlockLog,
    BadVersion,
    BadCheck,
};

const Archive = @This();

file: OffsetFile,

super: Superblock,

stateless_decomp: Decompressor,

/// Create an Archive from a File.
pub fn init(fil: std.fs.File, offset: u64) !Archive {
    var super: Superblock = undefined;
    var fil_rdr = fil.reader(&[0]u8{});
    if (offset > 0)
        try fil_rdr.seekTo(offset);
    try fil_rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    try super.validate();

    return .{
        .file = .{ .fil = fil, .offset = offset },
        .super = super,
        .stateless_decomp = .{ .vtable = &.{ .stateless = try DecompTypes.getStatelessFn(super.compression) } },
    };
}

pub fn extract(self: Archive, alloc: std.mem.Allocator, path: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = path;
    _ = options;
    return error.TODO;
}

pub fn root(self: Archive, alloc: std.mem.Allocator) !File {
    return .{
        .alloc = alloc,

        .inode = try Utils.refToInode(
            alloc,
            &self.stateless_decomp,
            self.file,
            self.super.inode_start,
            self.super.block_size,
            self.super.root_ref,
        ),
        .name = "",
    };
}
pub fn open(self: Archive, alloc: std.mem.Allocator, path: []const u8) !File {
    if (Utils.pathIsSelf(path)) return self.root(alloc);
    var root_file = self.root(alloc);
    defer root_file.deinit();
    return root_file.open(alloc, path);
}

pub fn fragEntry(self: Archive, idx: u32) !FragEntry {
    return LookupTable.stateless(FragEntry, self.fil, &self.stateless_decomp, self.super.frag_start, idx);
}
pub fn id(self: Archive, idx: u32) !u16 {
    return LookupTable.stateless(u16, self.fil, &self.stateless_decomp, self.super.id_start, idx);
}
pub fn inode(self: Archive, alloc: std.mem.Allocator, inode_num: u32) !Inode {
    const ref = try LookupTable.stateless(Inode.Ref, self.file, &self.stateless_decomp, self.super.export_start, inode_num - 1);
    return Utils.refToInode(alloc, &self.stateless_decomp, self.file, self.super.inode_start, self.super.block_size, ref);
}

// Superblock

const SQUASHFS_MAGIC: u32 = std.mem.readInt(u32, "hsqs", .little);

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: DecompTypes.Enum,
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
    fn validate(self: Superblock) !void {
        if (self.magic != SQUASHFS_MAGIC)
            return Error.BadMagic;
        if (self.flags.check)
            return Error.BadCheck;
        if (self.ver_maj != 4 or self.ver_min != 0)
            return Error.BadVersion;
        if (std.math.log2(self.block_size) != self.block_log)
            return Error.BadBlockLog;
    }

    pub fn toMinimal(self: Superblock) MinimalSuperblock {
        return .{
            .inode_count = self.inode_count,
            .block_size = self.block_size,
            .frag_count = self.frag_count,
            .id_count = self.id_count,
            .id_start = self.id_start,
            .xattr_start = self.xattr_start,
            .inode_start = self.inode_start,
            .dir_start = self.dir_start,
            .frag_start = self.frag_start,
            .export_start = self.export_start,
        };
    }
};

pub const MinimalSuperblock = struct {
    inode_count: u32,
    block_size: u32,
    frag_count: u32,
    id_count: u16,
    id_start: u64,
    xattr_start: u64,
    inode_start: u64,
    dir_start: u64,
    frag_start: u64,
    export_start: u64,
};

// Frag Entry

pub const FragEntry = packed struct {
    block_start: u64,
    size: BlockSize,
    _: u32,
};

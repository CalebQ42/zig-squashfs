const std = @import("std");

const Inode = @import("inode.zig");

const Archive = @This();

super: Superblock,

pub fn init(fil: std.fs.File, offset: u64) !Archive {
    var super: Superblock = undefined;
    var fil_rdr = fil.reader(&[0]u8{});
    try fil_rdr.seekTo(offset);
    try fil_rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);

    return .{
        .super = super,
    };
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
pub const Superblock = packed struct {
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
    fn validate(self: Superblock) !void {
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

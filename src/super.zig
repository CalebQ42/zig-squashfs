const math = @import("std").math;

const CompressionType = @import("decomp.zig").CompressionType;
const InodeRef = @import("inode.zig").Ref;

const SQUASHFS_MAGIC: u32 = "hsqs";

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
    compression: CompressionType,
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
    root_ref: InodeRef,
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
        if (self.magic.flags.check)
            return SuperblockError.InvalidCheck;
        if (self.ver_maj != 4 or self.ver_min != 0)
            return SuperblockError.InvalidVersion;
        if (math.log2(self.block_size) != self.block_log)
            return SuperblockError.InvalidBlockLog;
    }
};

const math = @import("std").math;

const Compressor = @import("decompress.zig").Compressor;
const InodeRef = @import("inode.zig").Ref;

const SuperblockError = error{
    InvalidMagic,
    InvalidBlockLog,
    InvalidVersion,
};

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compress: Compressor,
    block_log: u16,
    flags: u16,
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

    pub fn verify(self: Superblock) SuperblockError!void {
        if (self.magic != 0x73717368) return SuperblockError.InvalidMagic;
        if (math.log2(self.block_size) != self.block_log) return SuperblockError.InvalidBlockLog;
        if (self.ver_maj != 4 or self.ver_min != 0) return SuperblockError.InvalidVersion;
    }
};

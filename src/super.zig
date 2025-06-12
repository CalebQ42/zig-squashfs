const std = @import("std");

const CompressionType = @import("decomp.zig").CompressionType;
const InodeRef = @import("inode.zig").Ref;

const SuperblockError = error{
    BadMagic,
    BadBlockLog,
    InvalidVersion,
};

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    comp_type: CompressionType,
    block_log: u16,
    flags: u16,
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_inode: InodeRef,
    size: u64,
    id_start: u64,
    xattr_start: u64,
    inode_start: u64,
    dir_start: u64,
    frag_start: u64,
    export_start: u64,

    pub fn verify(self: Superblock) SuperblockError!void {
        if (self.magic != 0x73717368) return SuperblockError.BadMagic;
        if (self.ver_maj != 4 or self.ver_min != 0) return SuperblockError.InvalidVersion;
        if (std.math.log2(self.block_size) != self.block_size) return SuperblockError.BadBlockLog;
    }
};

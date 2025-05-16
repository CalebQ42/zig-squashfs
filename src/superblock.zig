const math = @import("std").math;

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
    decomp: @import("decompress.zig").DecompressType,
    block_log: u16,
    flags: u16,
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_ref: @import("inode/inode.zig").InodeRef,
    size: u64,
    id_table_start: u64,
    xattr_table_start: u64,
    inode_table_start: u64,
    dir_table_start: u64,
    frag_table_start: u64,
    export_table_start: u64,

    pub fn validate(self: Superblock) SuperblockError!void {
        if (self.magic != 0x73717368) {
            return SuperblockError.InvalidMagic;
        } else if (self.block_log != math.log2(self.block_size)) {
            return SuperblockError.InvalidBlockLog;
        } else if (self.ver_maj != 4 or self.ver_min != 0) {
            return SuperblockError.InvalidVersion;
        }
    }
};

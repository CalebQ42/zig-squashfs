const math = @import("std").math;
const InodeRef = @import("inode.zig").InodeRef;
const CompressionType = @import("decompress.zig").CompressionType;

pub const SuperblockError = error{
    InvalidMagic,
    InvalidLog,
    InvalidVersion,
};

pub const Superblock = packed struct {
    magic: u32,
    count: u32,
    mod_time: u32,
    block_size: u32,
    frags: u32,
    comp: CompressionType,
    block_log: u16,
    flags: packed struct {
        inode_uncomp: bool,
        data_uncomp: bool,
        _unused: bool,
        frag_uncomp: bool,
        frag_always: bool,
        data_dedupe: bool,
        export_table: bool,
        xattr_uncomp: bool,
        no_xattr: bool,
        comp_options: bool,
        id_uncomp: bool,
        _padding: u5,
    },
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_inode: InodeRef,
    size: u64,
    id_table: u64,
    xattr_table: u64,
    inode_table: u64,
    dir_table: u64,
    frag_table: u64,
    export_table: u64,

    pub fn valid(self: Superblock) SuperblockError!void {
        if (self.magic != 0x73717368) {
            return SuperblockError.InvalidMagic;
        } else if (self.block_log != math.log2(self.block_size)) {
            return SuperblockError.InvalidLog;
        } else if (self.ver_maj != 4 or self.ver_min != 0) {
            return SuperblockError.InvalidVersion;
        }
    }
};

const math = @import("std").math;

const InodeRef = @import("inode.zig").Ref;
const CompType = @import("util/decomp.zig").CompType;

pub const SuperblockErr = error{
    invalidMagic,
    invalidBlockLog,
    invalidVersion,
};

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    comp: CompType,
    block_log: u16,
    flags: packed struct {
        _: u4,
        ids_uncomp: bool,
        comp_options: bool,
        no_xattrs: bool,
        xattrs_uncomp: bool,
        exportable: bool,
        dedupe: bool,
        frag_always: bool,
        no_frag: bool,
        frag_uncomp: bool,
        check: bool,
        data_uncomp: bool,
        inode_uncomp: bool,
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

    pub fn validate(self: Superblock) !void {
        if (self.magic != 0x73717368) return SuperblockErr.invalidMagic;
        if (self.ver_maj != 4 or self.ver_min != 0) return SuperblockErr.invalidVersion;
        if (math.log2(self.block_size) != self.block_log) return SuperblockErr.invalidBlockLog;
    }
};

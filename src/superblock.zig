const std = @import("std");

const Compressor = @import("decompress.zig").Compressor;
const InodeRef = @import("inode.zig").InodeRef;

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compressor: Compressor,
    block_log: u16,
    flags: packed struct {
        _: u4,
        id_uncomp: bool,
        has_comp_options: bool,
        xattr_no: bool,
        xattr_uncomp: bool,
        has_export_table: bool,
        deduped: bool,
        frag_always: bool,
        frag_no: bool,
        frag_uncomp: bool,
        unused: bool,
        data_uncomp: bool,
        inodes_uncomp: bool,
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
};

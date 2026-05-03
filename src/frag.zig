const BlockSize = @import("inode_data/file.zig").BlockSize;

pub const FragEntry = extern struct {
    start: u64,
    size: BlockSize,
    _: u32,
};

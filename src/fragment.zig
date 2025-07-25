const BlockSize = @import("inode/file.zig").BlockSize;

pub const FragEntry = packed struct {
    block: u64,
    size: BlockSize,
    _: u32,
};

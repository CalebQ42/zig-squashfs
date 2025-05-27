const BlockSize = @import("inode/file.zig").BlockSize;
const Reader = @import("reader.zig").Reader;

pub const FragEntry = packed struct {
    start: u64,
    size: BlockSize,
    _: u32,

    pub fn getData(self: FragEntry, rdr: *Reader, offset: u32) ![]u8 {
        if (self.size.not_compressed) {
            //TODO
        }
    }
};

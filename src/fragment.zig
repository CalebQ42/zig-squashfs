const std = @import("std");

const BlockSize = @import("inode/file.zig").BlockSize;
const Reader = @import("reader.zig").Reader;

pub const FragEntry = packed struct {
    start: u64,
    size: BlockSize,
    _: u32,

    pub fn getData(self: FragEntry, rdr: *Reader, offset: u32, frag_size: u32) ![]u8 {
        var offset_rdr = rdr.holder.readerAt(self.start);
        if (self.size.not_compressed) {
            const buf = try rdr.alloc.alloc(u8, frag_size);
            _ = try offset_rdr.read(buf);
            return buf;
        }
        var limit_rdr = std.io.limitedReader(offset_rdr, self.size.size);
        var decomp = try rdr.super.decomp.decompress(rdr.alloc, limit_rdr.reader().any());
        var frag_all = try decomp.toOwnedSlice();
        defer rdr.alloc.free(frag_all);
        const out = try rdr.alloc.alloc(u8, frag_size);
        @memcpy(out, frag_all[offset .. offset + frag_size]);
        return out;
    }
};

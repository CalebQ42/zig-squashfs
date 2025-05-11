const std = @import("std");
const io = std.io;
const Superblock = @import("superblock.zig").Superblock;

pub const Reader = struct {
    super: Superblock,
    rdr: io.AnyReader,
};

pub fn newReader(rdr: io.AnyReader) !Reader {
    const super = try rdr.readStruct(Superblock);
    try super.valid();
    return Reader{
        .super = super,
        .rdr = rdr,
    };
}
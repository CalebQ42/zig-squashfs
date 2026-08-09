const std = @import("std");
const Io = std.Io;

const Archive = @This();

map: Io.File.MemoryMap,

super: Superblock,

pub fn open(io: Io, file: Io.File, offset: u64) !Archive {
    var map = try file.createMemoryMap(io, .{
        .len = try file.length(io) - offset,
        .offset = offset,
        .protection = .{ .read = true },
    });

    var super: Superblock = std.mem.bytesToValue(Superblock, map.memory[0..@sizeOf(Superblock)]);
    try super.check();

    return .{
        .map = map,

        .super = super,
    };
}

// Superblock

pub const Superblock = extern struct {
    pub const MAGIC: u32 = 0x73717368;

    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: u16,
    block_log: u16,
    flags: u16, // TODO: break out into packed struct.
    id_count: u16,
    version_major: u16,
    version_minor: u16,
    root_inode_ref: u64, // TODO: Change to inode reference packed struct.
    size: u64,
    id_table_start: u64,
    xattr_table_start: u64,
    inode_table_start: u64,
    dir_table_start: u64,
    frag_table_start: u64,
    export_table_start: u64,

    fn check(self: Superblock) !void {
        if (self.magic != MAGIC)
            return error.InvalidMagic;
        if (self.version_major != 4 or self.version_minor != 0)
            return error.IncompatibleVersion;
        if (std.math.log2(self.block_size) != self.block_log)
            return error.BadBlockLog;
    }
};

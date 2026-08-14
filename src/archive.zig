const std = @import("std");
const Io = std.Io;

const File = @import("file.zig");
const Inode = @import("inode.zig");
const Util = @import("utils/util.zig");
const Decomp = @import("decomp.zig");

const Options = @import("options.zig");

const Archive = @This();

map: Io.File.MemoryMap,

super: Super,

pub fn open(io: Io, file: Io.File, offset: u64) !Archive {
    var map = try file.createMemoryMap(io, .{
        .len = try file.length(io) - offset,
        .offset = offset,
        .protection = .{ .read = true },
    });

    var superblock = Util.readValue(Superblock, map.memory[0..@sizeOf(Superblock)]);
    const super = try superblock.check();

    return .{
        .map = map,

        .super = super,
    };
}
pub fn close(self: *Archive, io: Io) void {
    self.map.destroy(io);
}

pub fn root(self: *Archive) !File {
    _ = self;
    return error.TODO;
}
pub fn extract(self: *Archive, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: Options) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = ext_loc;
    _ = options;
    return error.TODO;
}

// Superblock

const Superblock = extern struct {
    pub const MAGIC: u32 = 0x73717368;

    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: Decomp.Enum,
    block_log: u16,
    flags: u16, // TODO: break out into packed struct.
    id_count: u16,
    version_major: u16,
    version_minor: u16,
    root_inode_ref: Inode.Reference, // TODO: Change to inode reference packed struct.
    size: u64,
    id_table_start: u64,
    xattr_table_start: u64,
    inode_table_start: u64,
    dir_table_start: u64,
    frag_table_start: u64,
    export_table_start: u64,

    fn check(self: Superblock) !Super {
        if (self.magic != MAGIC)
            return error.InvalidMagic;
        if (self.version_major != 4 or self.version_minor != 0)
            return error.IncompatibleVersion;
        if (std.math.log2(self.block_size) != self.block_log)
            return error.BadBlockLog;

        return .{
            .block_size = self.block_size,
            .frag_count = self.frag_count,
            .decomp_fn = try self.compression.func(),
            .id_count = self.id_count,
            .root_inode_ref = self.root_inode_ref,
            .id_table_start = self.id_table_start,
            .xattr_table_start = self.xattr_table_start,
            .inode_table_start = self.inode_table_start,
            .dir_table_start = self.dir_table_start,
            .frag_table_start = self.frag_table_start,
            .export_table_start = self.export_table_start,
        };
    }
};
pub const Super = struct {
    block_size: u32,
    frag_count: u32,
    decomp_fn: Decomp.Fn,
    id_count: u16,
    root_inode_ref: Inode.Reference,
    id_table_start: u64,
    xattr_table_start: u64,
    inode_table_start: u64,
    dir_table_start: u64,
    frag_table_start: u64,
    export_table_start: u64,
};

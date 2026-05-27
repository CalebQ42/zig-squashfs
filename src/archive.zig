const std = @import("std");
const Io = std.Io;
const MemoryMap = Io.File.MemoryMap;

const c = @import("c");
const config = @import("config");

const Superblock = @import("super.zig").Superblock;
const DecompCache = @import("util/decomp_cache.zig");
const CompressionType = @import("util/decompress.zig").CompressionType;

const Archive = @This();

map: MemoryMap,
cache: DecompCache,

super: Superblock,

pub fn init(alloc: std.mem.Allocator, io: Io, file: Io.File, offset: u64, max_cache_size: u64) !Archive {
    var rdr = file.reader(io, &[0]u8{});
    try rdr.seekTo(offset);

    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    try super.validate();

    if (!config.use_zig_decomp and config.allow_lzo)
        _ = c.lzo_init();

    const map = try file.createMemoryMap(
        io,
        .{ .offset = offset, .len = super.size, .protection = .{ .read = true } },
    );
    return .{
        .map = map,
        .cache = try .init(alloc, map, super.compression, max_cache_size),

        .super = super,
    };
}
pub fn deinit(self: *Archive, io: Io) void {
    self.map.destroy(io);
}

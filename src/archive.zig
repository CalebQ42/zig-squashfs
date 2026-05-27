const std = @import("std");
const Io = std.Io;
const MemoryMap = Io.File.MemoryMap;

const c = @import("c");
const config = @import("config");

const ExtractionOptions = @import("options.zig");
const File = @import("file.zig");
const Superblock = @import("super.zig").Superblock;
const DecompCache = @import("util/decomp_cache.zig");
const CompressionType = @import("util/decompress.zig").CompressionType;

const Archive = @This();

const CACHE_MIN = 16 * 1024 * 1024;
const CACHE_MAX = 1 * 1024 * 1024 * 1024;

map: MemoryMap,
cache: DecompCache,

super: Superblock,

/// Open a squashfs archive from an Io.File.
pub fn init(alloc: std.mem.Allocator, io: Io, fil: Io.File) !Archive {
    return initAdvanced(alloc, io, fil, 0, 0);
}
/// If max_cache_size is zero, a size is selected based on system ram, up to 1GB with a minimum of 16MB.
pub fn initAdvanced(alloc: std.mem.Allocator, io: Io, file: Io.File, offset: u64, max_cache_size: u64) !Archive {
    var rdr = file.reader(io, &[0]u8{});
    try rdr.seekTo(offset);

    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    try super.validate();

    if (!config.use_zig_decomp and config.allow_lzo)
        _ = c.lzo_init();

    const map = try file.createMemoryMap(
        io,
        .{
            .offset = offset,
            .len = super.size,
            .protection = .{ .read = true },
        },
    );
    const cache_size = blk: {
        if (max_cache_size > CACHE_MIN) break :blk CACHE_MIN;
        const sys_mem = std.process.totalSystemMemory() catch break :blk CACHE_MIN;
        var min = @min(CACHE_MAX, sys_mem / 4);
        if (min < CACHE_MIN and sys_mem > CACHE_MIN)
            min = CACHE_MIN;
        break :blk min;
    };
    return .{
        .map = map,
        .cache = try .init(
            alloc,
            map,
            super.compression,
            cache_size,
        ),

        .super = super,
    };
}
pub fn deinit(self: *Archive, io: Io) void {
    self.cache.deinit(io);
    self.map.destroy(io);
}

pub fn root(self: *Archive, alloc: std.mem.Allocator, io: Io) !File {
    return .fromRef(alloc, io, self, "", self.super.root_ref);
}

pub fn open(self: *Archive, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    const path = std.mem.trim(u8, filepath, "/");

    var root_file = try self.root(alloc, io);

    if (path.len == 0 or std.mem.eql(u8, path, ".")) return root_file;
    defer root_file.deinit();

    return root_file.open(alloc, io, path);
}

pub fn extract(self: *Archive, alloc: std.mem.Allocator, io: Io, ext_dir: []const u8, options: ExtractionOptions) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = ext_dir;
    _ = options;
    return error.TODO;
}

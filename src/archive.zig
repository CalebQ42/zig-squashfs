const std = @import("std");
const Io = std.Io;
const MemoryMap = Io.File.MemoryMap;

const Decomp = @import("decomp.zig");
const Inode = @import("inode.zig");
const File = @import("file.zig");
const ExtractionOptions = @import("options.zig");
const Extract = @import("extract.zig");

const Archive = @This();

super: Superblock,

map: MemoryMap,
decomp: Decomp.Fn,

pub fn init(io: Io, file: Io.File, offset: u64) !Archive {
    var rdr = file.reader(io, &[0]u8{});
    try rdr.seekTo(offset);

    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);

    try super.validate();

    return .{
        .super = super,

        .map = try file.createMemoryMap(io, .{
            .offset = offset,
            .len = super.size,
            .protection = .{ .read = true },
        }),
        .decomp = try Decomp.getFn(super.compression),
    };
}
pub fn deinit(self: *Archive, io: Io) void {
    self.map.destroy(io);
}

pub fn root(self: Archive, alloc: std.mem.Allocator) !File {
    return .initRef(alloc, self.super, self.map.memory, self.decomp, "", self.super.root_ref);
}

pub fn open(self: Archive, alloc: std.mem.Allocator, filepath: []const u8) !File {
    const root_file = try self.root(alloc);

    const path = std.mem.trim(u8, filepath, "/");

    if (path.len == 0 or (path.len == 1 and path[0] == '.'))
        return root_file;

    defer root_file.deinit();

    return root_file.open(alloc, filepath);
}

pub fn extract(self: Archive, alloc: std.mem.Allocator, io: Io, location: []const u8, options: ExtractionOptions) !void {
    const root_inode: Inode = try .initRef(
        alloc,
        self.map.memory,
        self.decomp,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    defer root_inode.deinit(alloc);

    return root_inode.extract(alloc, io, self.super, self.map.memory, self.decomp, location, options);
}

// Superblock

const SQUASHFS_MAGIC: u32 = std.mem.readInt(u32, "hsqs", .little);

const SuperblockError = error{
    InvalidMagic,
    InvalidBlockLog,
    InvalidVersion,
    InvalidCheck,
};

/// A squashfs Superblock
pub const Superblock = extern struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: Decomp.Enum,
    block_log: u16,
    flags: packed struct(u16) {
        inode_uncompressed: bool,
        data_uncompressed: bool,
        check: bool,
        frag_uncompressed: bool,
        fragment_never: bool,
        fragment_always: bool,
        duplicates: bool,
        exportable: bool,
        xattr_uncompressed: bool,
        xattr_never: bool,
        compression_options: bool,
        ids_uncompressed: bool,
        _: u4,
    },
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_ref: Inode.Ref,
    size: u64,
    id_start: u64,
    xattr_start: u64,
    inode_start: u64,
    dir_start: u64,
    frag_start: u64,
    export_start: u64,

    /// Validate the Superblock. If an error is returned, it's likely the archive is corrupted or not a squashfs archive.
    pub fn validate(self: Superblock) !void {
        if (self.magic != SQUASHFS_MAGIC)
            return SuperblockError.InvalidMagic;
        if (self.flags.check)
            return SuperblockError.InvalidCheck;
        if (self.ver_maj != 4 or self.ver_min != 0)
            return SuperblockError.InvalidVersion;
        if (std.math.log2(self.block_size) != self.block_log)
            return SuperblockError.InvalidBlockLog;
    }
};

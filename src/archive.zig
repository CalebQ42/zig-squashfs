const std = @import("std");
const Io = std.Io;
const File = Io.File;
const MemoryMap = File.MemoryMap;

const Decomp = @import("decomp.zig");
const DecompCache = @import("decomp_cache.zig");
const Extract = @import("extract.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const SfsFile = @import("file.zig");

const Archive = @This();

const CACHE_MEM_MAX = 1024 * 1024 * 1024;

super: Superblock,

cache: DecompCache,

pub fn init(alloc: std.mem.Allocator, io: Io, fil: File) !Archive {
    return initAdvanced(alloc, io, fil, 0, 0);
}
pub fn initAdvanced(alloc: std.mem.Allocator, io: Io, fil: File, offset: u64, cache_memory_max: u64) !Archive {
    var rdr = fil.reader(io, &[0]u8{});
    try rdr.seekTo(offset);
    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    try super.validate();

    const map = try fil.createMemoryMap(io, .{
        .offset = offset,
        .len = super.size,
        .protection = .{ .read = true },
    });

    return .{
        .super = super,

        .cache = try .init(
            alloc,
            map,
            super.compression,
            if (cache_memory_max != 0)
                cache_memory_max
            else
                @min(CACHE_MEM_MAX, (try std.process.totalSystemMemory()) / 2),
        ),
    };
}
pub fn deinit(self: *Archive, io: Io) void {
    self.cache.deinit(io);
}

pub fn root(self: *Archive, alloc: std.mem.Allocator, io: Io) !SfsFile {
    const inode: Inode = try .initRef(
        alloc,
        io,
        &self.cache,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    return .init(alloc, self, inode, "");
}
pub fn open(self: *Archive, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !SfsFile {
    const path = std.mem.trim(u8, filepath, "/");

    var root_file = try self.root(alloc, io);

    if (path.len == 0 or path[0] == '.') return root_file;

    defer root_file.deinit();
    return root_file.open(alloc, io, filepath);
}

pub fn extract(self: *Archive, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: ExtractionOptions) !void {
    const root_inode: Inode = try .initRef(
        alloc,
        io,
        &self.cache,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    return Extract.extract(alloc, io, root_inode, &self.cache, self.super, ext_loc, options);
}

// Superblock

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
        frag_never: bool,
        frag_always: bool,
        de_dupe: bool,
        exportable: bool,
        xattr_uncompressed: bool,
        xattr_never: bool,
        compression_options: bool,
        id_uncompressed: bool,
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

    pub fn validate(self: Superblock) !void {
        if (self.magic != std.mem.readInt(u32, "hsqs", .little))
            return error.BadMagic;
        if (self.ver_maj != 4 or self.ver_min != 0)
            return error.InvalidVersion;
        if (self.block_log != std.math.log2(self.block_size))
            return error.BadBlockLog;
        if (self.flags.check)
            return error.BadCheckFlag;
    }
};

// Test

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = try .init(alloc, io, archive_file);
    defer arc.deinit(io);

    var root_file = try arc.root(alloc, io);
    defer root_file.deinit();
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "SingleFileExtraction" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = try .init(alloc, io, archive_file);
    defer arc.deinit(io);

    var ext_file = try arc.open(alloc, io, TestFile);
    defer ext_file.deinit();

    try ext_file.extract(alloc, io, TestFileExtractLocation, .default);
}

const TestFullExtractLocation = "testing/TestExtract";

test "FullExtraction" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = try .init(alloc, io, archive_file);
    defer arc.deinit(io);

    try arc.extract(alloc, io, TestFullExtractLocation, .default);
}

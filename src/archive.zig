const std = @import("std");
const Io = std.Io;
const File = Io.File;
const MemoryMap = File.MemoryMap;

const Decomp = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const SfsFile = @import("file.zig");

const Archive = @This();

map: MemoryMap,

decomp: Decomp.Fn,

pub fn init(io: Io, fil: File) !Archive {
    return initAdvanced(io, fil, 0);
}
pub fn initAdvanced(io: Io, fil: File, offset: u64) !Archive {}
pub fn deinit(self: *Archive, io: Io) void {
    self.map.destroy(io);
}

pub fn root(self: Archive, alloc: std.mem.Allocator) !SfsFile {}
pub fn open(self: Archive, alloc: std.mem.Allocator, filepath: []const u8) !SfsFile {}

pub fn extract(self: Archive, alloc: std.mem.Allocator, io: Io, ext_loc: []const u8, options: ExtractionOptions) !void {}

// Superblock

pub const Superblock = extern struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    compression: Decomp.Enum,
    block_log: u16,
    flags: packed struct(u16) {},
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
};

// Test

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = .init(io, archive_file);
    defer arc.deinit(io);

    var root_file = try arc.root(alloc);
    defer root_file.deinit();
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "SingleFileExtraction" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = .init(io, archive_file);
    defer arc.deinit(io);

    var ext_file = try arc.open(alloc, TestFile);
    defer ext_file.deinit();

    try ext_file.extract(alloc, io, TestFileExtractLocation, .default);
}

const TestFullExtractLocation = "testing/TestExtract";

test "FullExtraction" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);
    var arc: Archive = .init(io, archive_file);
    defer arc.deinit(io);

    try arc.extract(alloc, io, TestFullExtractLocation, .default);
}

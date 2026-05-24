const std = @import("std");
const Io = std.Io;

const Decomp = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const File = @import("file.zig");
const Inode = @import("inode.zig");
const LookupTable = @import("lookup_table.zig");
const Decompressor = @import("util/decompressor.zig");
const MetadataReader = @import("util/metadata.zig");
const Utils = @import("util/misc.zig");
const OffsetFile = @import("util/offset_file.zig");

const Archive = @This();

file: OffsetFile,
super: Superblock,

stateless_decomp: *const Decompressor,

pub fn init(io: Io, file: std.Io.File, offset: u64) !Archive {
    var rdr = file.reader(io, &[0]u8{});
    try rdr.seekTo(offset);
    var super: Superblock = undefined;
    try rdr.interface.readSliceEndian(Superblock, @ptrCast(&super), .little);
    try super.validate();

    return .{
        .file = try .init(io, file, super.size, offset),
        .super = super,

        .stateless_decomp = try Decomp.StatelessDecomp(super.compression),
    };
}
pub fn deinit(self: *Archive, io: Io) void {
    self.file.deinit(io);
}

/// The root folder of the Archive. Used to open other Files.
pub fn root(self: Archive, alloc: std.mem.Allocator) !File {
    const root_inode = try Utils.inodeFromRef(
        alloc,
        self.file,
        self.stateless_decomp,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    return .init(alloc, self, root_inode, "");
}
/// Opens a File within the archive.
pub fn open(self: Archive, alloc: std.mem.Allocator, io: Io, filepath: []const u8) !File {
    const root_file = try self.root(alloc);
    const path = std.mem.trim(u8, filepath, "/");
    if (Utils.pathIsSelf(path))
        return root_file;
    defer root_file.deinit();
    return root_file.open(alloc, io, filepath);
}

/// Returns the inode with the given inode number.
/// Requires that the archive is exportable (has an export lookup table).
pub fn inode(self: Archive, alloc: std.mem.Allocator, io: Io, num: u32) !Inode {
    if (!self.super.flags.exportable)
        return error.NotExportable;
    const ref = try LookupTable.lookupValue(
        Inode.Ref,
        alloc,
        io,
        &self.stateless_decomp,
        self.file,
        self.super.export_start,
        num + 1,
    );
    return Utils.inodeFromRef(
        alloc,
        io,
        self.file,
        &self.stateless_decomp,
        self.super.inode_start,
        self.super.block_size,
        ref,
    );
}
/// Returns a value at the given index from the Archive's id (uid/gid) table.
pub fn idTable(self: Archive, alloc: std.mem.Allocator, io: Io, idx: u32) !u16 {
    return LookupTable.lookupValue(
        u16,
        alloc,
        io,
        &self.stateless_decomp,
        self.file,
        self.super.id_start,
        idx,
    );
}

/// Extract the entire archive contents to the given directory.
pub fn extract(self: Archive, alloc: std.mem.Allocator, io: Io, extract_dir: []const u8, options: ExtractionOptions) !void {
    const root_inode = try Utils.inodeFromRef(
        alloc,
        self.file,
        self.stateless_decomp,
        self.super.inode_start,
        self.super.block_size,
        self.super.root_ref,
    );
    return root_inode.extract(alloc, io, self.file, self.super, extract_dir, options);
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

// Tests

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    std.debug.print("Starting test: Basics...\n", .{});

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var fil = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer fil.close(io);
    var sfs: Archive = try .init(io, fil, 0);
    defer sfs.deinit(io);
    try std.testing.expectEqualDeep(sfs.super, LinuxPATestCorrectSuperblock);
    const root_file = try sfs.root(alloc);
    defer root_file.deinit();
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "ExtractSingleFile" {
    std.debug.print("Starting test: ExtractSingleFile...\n", .{});

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    Io.Dir.cwd().deleteFile(io, TestFileExtractLocation) catch {};
    var fil = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer fil.close(io);
    var sfs: Archive = try .init(io, fil, 0);
    defer sfs.deinit(io);
    var test_fil = try sfs.open(alloc, io, TestFile);
    defer test_fil.deinit();
    try test_fil.extract(alloc, io, TestFileExtractLocation, .default);
    //TODO: validate extracted file.
}

const TestFullExtractLocation = "testing/TestExtract";

test "ExtractCompleteArchive" {
    std.debug.print("Starting test: ExtractCompleteArchive...\n", .{});

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    Io.Dir.cwd().deleteTree(io, TestFullExtractLocation) catch {};
    var fil = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer fil.close(io);
    var sfs: Archive = try .init(io, fil, 0);
    defer sfs.deinit(io);
    try sfs.extract(alloc, io, TestFullExtractLocation, .default);
}

test "ExtractCompleteArchiveSingleThreaded" {
    std.debug.print("Starting test: ExtractCompleteArchive...\n", .{});

    const alloc = std.testing.allocator;
    var threaded: Io.Evented = undefined;
    try threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var signal: u32 = 0;

    Io.Dir.cwd().deleteTree(io, TestFullExtractLocation) catch {};

    const tmp = struct {
        fn singleThreadedExtract(sig: *u32) !void {
            var fil = try Io.Dir.cwd().openFile(Io.Threaded.global_single_threaded.io(), TestArchive, .{});
            defer fil.close(Io.Threaded.global_single_threaded.io());
            var sfs: Archive = try .init(Io.Threaded.global_single_threaded.io(), fil, 0);
            defer sfs.deinit(Io.Threaded.global_single_threaded.io());
            try sfs.extract(std.testing.allocator, Io.Threaded.global_single_threaded.io(), TestFullExtractLocation, .default);
            sig.* = 1;
        }
    };
    var ret = try io.concurrent(tmp.singleThreadedExtract, .{&signal});
    try io.futexWaitTimeout(
        u32,
        &signal,
        0,
        .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }) },
    );
    if (ret.any_future == null) return ret.result;
    try ret.cancel(io);
    return error.TestTimeout;
}

const LinuxPATestCorrectSuperblock: Superblock = .{
    .magic = std.mem.readInt(u32, "hsqs", .little),
    .inode_count = 2974,
    .mod_time = 1632696724,
    .block_size = 131072,
    .frag_count = 264,
    .compression = .zstd,
    .block_log = 17,
    .flags = .{
        .inode_uncompressed = false,
        .data_uncompressed = false,
        .check = false,
        .frag_uncompressed = false,
        .fragment_never = false,
        .fragment_always = false,
        .duplicates = true,
        .exportable = true,
        .xattr_uncompressed = false,
        .xattr_never = false,
        .compression_options = false,
        .ids_uncompressed = false,
        ._ = 0,
    },
    .id_count = 1,
    .ver_maj = 4,
    .ver_min = 0,
    .root_ref = .{
        .block_offset = 1363,
        .block_start = 29237,
        ._ = 0,
    },
    .size = 106841744,
    .id_start = 106841632,
    .xattr_start = 106841720,
    .inode_start = 106778274,
    .dir_start = 106807998,
    .frag_start = 106837747,
    .export_start = 106841602,
};

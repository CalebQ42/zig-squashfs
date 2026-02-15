const std = @import("std");
const stuff = @import("builtin");

const Archive = @import("archive.zig");
const Superblock = @import("super.zig").Superblock;

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    var fil = try std.fs.cwd().openFile(TestArchive, .{});
    defer fil.close();
    const sfs: Archive = try .init(fil, 0);
    if (sfs.super != LinuxPATestCorrectSuperblock) {
        std.debug.print("Superblock wrong\nShould be: {}\n\nis: {}\n", .{ LinuxPATestCorrectSuperblock, sfs.super });
        return error.BadSuperblock;
    }
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "ExtractSingleFile" {
    std.fs.cwd().deleteFile(TestFileExtractLocation) catch {};
    var fil = try std.fs.cwd().openFile(TestArchive, .{});
    defer fil.close();
    var sfs: Archive = try .init(fil, 0);
    var test_fil = try sfs.open(std.testing.allocator, TestFile);
    defer test_fil.deinit();
    try test_fil.extract(std.testing.allocator, TestFileExtractLocation, try .Default());
    //TODO: validate extracted file.
}

const TestFullExtractLocation = "testing/TestExtract";

test "ExtractCompleteArchive" {
    std.fs.cwd().deleteTree(TestFullExtractLocation) catch {};
    var fil = try std.fs.cwd().openFile(TestArchive, .{});
    defer fil.close();
    var sfs: Archive = try .init(fil, 0);
    try sfs.extract(std.testing.allocator, TestFullExtractLocation, try .Default());
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

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const Archive = @import("archive.zig");

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    const io = testing.io;
    const alloc = testing.allocator;

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);

    var archive: Archive = try .init(io, archive_file, 0);
    defer archive.deinit(io);

    try testing.expectEqualDeep(archive.super, LinuxPATestCorrectSuperblock);

    var root = try archive.root(alloc);
    defer root.deinit();
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "ExtractSingleFileMT" {
    const io = testing.io;
    const alloc = testing.allocator;

    Io.Dir.cwd().deleteFile(io, TestFileExtractLocation) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);

    var archive: Archive = try .init(io, archive_file, 0);
    defer archive.deinit(io);

    var start_exe = try archive.open(alloc, TestFile);
    defer start_exe.deinit();

    try start_exe.extract(alloc, io, TestFileExtractLocation, .default);
}

test "ExtractSingleFileST" {
    const io = testing.io;
    const alloc = testing.allocator;

    Io.Dir.cwd().deleteFile(io, TestFileExtractLocation) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);

    var archive: Archive = try .init(io, archive_file, 0);
    defer archive.deinit(io);

    var start_exe = try archive.open(alloc, TestFile);
    defer start_exe.deinit();

    try start_exe.extract(alloc, io, TestFileExtractLocation, .single_threaded_default);
}

const TestFullExtractLocationSTOption = "testing/TestExtractSTOption";

test "ExtractCompleteArchiveSingleThreadedOption" {
    const io = testing.io;
    const alloc = testing.allocator;

    Io.Dir.cwd().deleteTree(io, TestFullExtractLocationSTOption) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);

    var archive: Archive = try .init(io, archive_file, 0);
    defer archive.deinit(io);

    try archive.extract(alloc, io, TestFullExtractLocationSTOption, .single_threaded_default);
}

const TestFullExtractLocationMT = "testing/TestExtractMT";

test "ExtractCompleteArchiveMultiThreaded" {
    const io = testing.io;
    const alloc = testing.allocator;

    Io.Dir.cwd().deleteTree(io, TestFullExtractLocationMT) catch {};

    var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
    defer archive_file.close(io);

    var archive: Archive = try .init(io, archive_file, 0);
    defer archive.deinit(io);

    try archive.extract(alloc, io, TestFullExtractLocationMT, .default);
}

const TestFullExtractLocationSTIo = "testing/TestExtractSTIo";

// test "ExtractCompleteArchiveSingleThreadedIo" {
//     const io = Io.Threaded.global_single_threaded.io();
//     const alloc = testing.allocator;

//     Io.Dir.cwd().deleteFile(io, TestFullExtractLocationSTIo) catch {};

//     var archive_file = try Io.Dir.cwd().openFile(io, TestArchive, .{});
//     defer archive_file.close(io);

//     var archive: Archive = try .init(io, archive_file, 0);
//     defer archive.deinit(io);

//     try archive.extract(alloc, io, TestFullExtractLocationSTIo, .default);
// }

const LinuxPATestCorrectSuperblock: Archive.Superblock = .{
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

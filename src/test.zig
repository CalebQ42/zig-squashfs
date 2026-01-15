const std = @import("std");
const stuff = @import("builtin");

const Archive = @import("archive.zig");
const Superblock = @import("super.zig");

const TestArchive = "testing/LinuxPATest.sfs";

test "Basics" {
    var fil = try std.fs.cwd().openFile(TestArchive);
    defer fil.close();
    var sfs: Archive = try .init(std.testing.allocator, fil);
    defer sfs.deinit();
}

const TestFile = "Start.exe";
const TestFileExtractLocation = "testing/Start.exe";

test "ExtractSingleFile" {}

const TestFullExtractLocation = "testing/TestExtract";

test "ExtractCompleteArchive" {}

const CorrectSuperblock = Superblock{
    .magic = "hsqs",
};

const std = @import("std");
const debug = std.debug;
const squashfs = @import("squashfs.zig");

const testFileName = "testing/LinuxPATest.sfs";

test "open test file" {
    const testFile = try std.fs.cwd().openFile(
        testFileName,
        .{},
    );
    defer testFile.close();
    const reader = try squashfs.newReader(testFile.reader().any());
    _ = reader;
}

const std = @import("std");
const debug = std.debug;
const squashfs = @import("squashfs.zig");

const testFileName = "testing/LinuxPATest.sfs";

test "open test file" {
    const reader = try squashfs.newReader(testFileName);
    defer reader.close();
}

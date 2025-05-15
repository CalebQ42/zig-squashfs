const std = @import("std");
const debug = std.debug;
const squashfs = @import("squashfs.zig");
const print = std.debug.print;

const testFileName = "testing/LinuxPATest.sfs";

test "open test file" {
    var reader = try squashfs.newReader(testFileName);
    defer reader.deinit();
    const fil = try reader.open("PortableApps/Desktop.ini");
    std.debug.print("{s}\n", .{fil.name});
}

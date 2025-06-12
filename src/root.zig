const std = @import("std");

pub const SfsReader = @import("reader.zig").SfsReader;

pub fn openFile(path: []const u8) !SfsReader(std.fs.File) {
    const fil = try std.fs.cwd().openFile(path, .{});
    defer fil.close();
    return .init(fil);
}

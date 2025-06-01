const std = @import("std");
const fs = std.fs;

const File = std.fs.File;
const PReader = @import("preader.zig").PReader;

pub fn SfsReader(
    comptime preader: type,
) type {
    // std.debug.assert(std.mem.eql(u8, @typeName(preader), "PReader"));
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: preader,

        pub fn init(alloc: std.mem.Allocator, rdr: preader) !Self {
            return .{
                .alloc = alloc,
                .rdr = rdr,
            };
        }
    };
}

test "open sfs archive" {
    const testFile = "testing/LinuxPATest.sfs";
    const fil = try fs.cwd().openFile(testFile, .{});
    defer fil.close();
}

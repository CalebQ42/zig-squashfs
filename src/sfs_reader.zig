const std = @import("std");
const fs = std.fs;

const File = std.fs.File;

const PReader = @import("preader.zig").PReader;

pub fn SfsReader(
    comptime Context: type,
    comptime ErrorType: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) ErrorType!usize,
) type {
    return struct {
        const Self = @This();
        const PRdr = PReader(Context, ErrorType, preadFn);

        alloc: std.mem.Allocator,
        rdr: PRdr,

        pub fn init(alloc: std.mem.Allocator, rdr: Context) !Self {
            return .{
                .alloc = alloc,
                .rdr = .init(rdr),
            };
        }
        pub fn initWOffset(alloc: std.mem.Allocator, rdr: Context, offset: u64) !Self {
            return .{
                .alloc = alloc,
                .rdr = .initWithOffset(rdr, offset),
            };
        }
    };
}

test "open sfs archive" {
    const testFile = "testing/LinuxPATest.sfs";
    const fil = try fs.cwd().openFile(testFile, .{});
    defer fil.close();
}

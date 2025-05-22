const std = @import("std");

const Reader = @import("reader.zig");

const stdout = std.io.getStdOut();

pub fn main() !void {
    const alloc: std.heap.GeneralPurposeAllocator(.{}) = .init();
    const args = try std.process.argsWithAllocator(alloc.allocator());
    defer args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            help();
            return;
        }
    }
    //TODO
}

fn help() void {}

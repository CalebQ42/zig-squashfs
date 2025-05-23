const std = @import("std");

const Reader = @import("reader.zig");

const stdout = std.io.getStdOut();

pub fn main() !void {
    var alloc: std.heap.GeneralPurposeAllocator(.{}) = .init;
    var args = try std.process.argsWithAllocator(alloc.allocator());
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

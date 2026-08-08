const std = @import("std");
const Io = std.Io;

const Archive = @This();

map: Io.File.MemoryMap,

pub fn open(io: Io, file: Io.File, offset: u64) !Archive {
    return .{
        .map = try file.createMemoryMap(io, .{
            .len = super.size,
            .offset = offset,
            .protection = .{ .read = true },
        }),
    };
}

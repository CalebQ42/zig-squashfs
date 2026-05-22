//! A File where it's meaningful (to us) content starts at a given offset.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Reader = Io.Reader;

const OffsetFile = @This();

map: Io.File.MemoryMap,

pub fn init(io: Io, fil: File, archive_size: u64, init_offset: u64) !OffsetFile {
    return .{
        .map = try fil.createMemoryMap(io, .{
            .protection = .{ .read = true, .write = false, .execute = false },
            .len = archive_size,
            .offset = init_offset,
        }),
    };
}
pub fn deinit(self: @This(), io: Io) void {
    self.map.destroy(io);
}

pub fn readerAt(self: OffsetFile, offset: u64) Reader {
    return .fixed(self.map.memory[offset..]);
}

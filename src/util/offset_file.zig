//! A File where it's meaningful (to us) content starts at a given offset.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Reader = File.Reader;

const OffsetFile = @This();

fil: File,
offset: u64,

pub fn init(fil: File, init_offset: u64) OffsetFile {
    return .{ .fil = fil, .offset = init_offset };
}

pub fn readerAt(self: OffsetFile, io: Io, offset: u64, buffer: []u8) Reader.SeekError!Reader {
    var rdr = self.fil.reader(io, buffer);
    try rdr.seekTo(self.offset + offset);
    return rdr;
}
pub fn readAt(self: OffsetFile, io: Io, offset: u64, buf: []u8) File.ReadPositionalError!void {
    _ = try self.fil.readPositionalAll(io, buf, self.offset + offset);
}

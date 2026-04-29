//! A File where it's meaningful (to us) content starts at a given offset.

const std = @import("std");
const File = std.Io.File;
const Reader = File.Reader;

const OffsetFile = @This();

fil: File,
offset: u64,

pub fn init(fil: File, init_offset: u64) OffsetFile {
    return .{ .fil = fil, .offset = init_offset };
}

pub fn readerAt(self: OffsetFile, io: std.Io, offset: u64, buffer: []u8) !Reader {
    var rdr = self.fil.reader(io, buffer);
    try rdr.seekTo(self.offset + offset);
    return rdr;
}

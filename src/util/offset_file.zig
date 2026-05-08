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

pub fn readerAt(self: OffsetFile, io: Io, offset: u64, buffer: []u8) !Reader {
    var rdr = self.fil.reader(io, buffer);
    try rdr.seekTo(self.offset + offset);
    return rdr;
}
pub fn readAt(self: OffsetFile, io: Io, offset: u64, buf: []u8) !void {
    _ = try self.fil.readPositionalAll(io, buf, self.offset + offset);
}
pub fn readValueAt(self: OffsetFile, comptime T: anytype, io: Io, offset: u64) !void {
    //TODO: check for endianess and decode accordingly.
    var new: T = undefined;
    _ = try self.fil.readPositionalAll(io, @ptrCast(&new), self.offset + offset);
}

const std = @import("std");
const Io = std.Io;
const FileReader = Io.File.Reader;

const OffsetFile = @This();

fil: Io.File,
offset: u64 = 0,

pub fn readerAt(self: OffsetFile, io: Io, offset: u64, buf: []u8) !FileReader {
    var rdr = self.fil.reader(io, buf);
    try rdr.seekTo(self.offset + offset);
    return rdr;
}
pub fn valueAt(self: OffsetFile, comptime T: type, io: Io, offset: u64) !T {
    var rdr = self.fil.reader(io, &[0]u8{});
    try rdr.seekTo(self.offset + offset);
    var new: T = undefined;
    try rdr.interface.readSliceEndian(T, @ptrCast(&new), .little);
    return new;
}

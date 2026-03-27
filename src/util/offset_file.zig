const std = @import("std");
const FileReader = std.fs.File.Reader;

const OffsetFile = @This();

fil: std.fs.File,
offset: u64 = 0,

pub fn readerAt(self: OffsetFile, offset: u64, buf: []u8) !FileReader {
    var rdr = self.fil.reader(buf);
    try rdr.seekTo(self.offset + offset);
    return rdr;
}
pub fn valueAt(self: OffsetFile, comptime T: type, offset: u64) !T {
    var rdr = self.fil.reader(&[0]u8{});
    try rdr.seekTo(self.offset + offset);
    var new: T = undefined;
    try rdr.interface.readSliceEndian(T, @ptrCast(&new), .little);
    return new;
}

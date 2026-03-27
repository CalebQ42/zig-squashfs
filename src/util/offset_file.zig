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

const std = @import("std");

const FileOffsetReader = struct {
    file: std.fs.File,

    pub fn any(self: *FileOffsetReader) !std.io.AnyReader {}
};

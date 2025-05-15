const std = @import("std");

pub const FileOffsetReader = struct {
    file: *std.fs.File,
    offset: u64,

    pub fn init(file: *std.fs.File, initial_offset: u64) FileOffsetReader {
        return .{
            .file = file,
            .offset = initial_offset,
        };
    }

    pub fn read(self: *FileOffsetReader, bytes: []u8) anyerror!usize {
        const red = try self.file.preadAll(bytes, self.offset);
        self.offset += @intCast(red);
        return red;
    }

    pub fn any(self: *FileOffsetReader) std.io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = readOpaque,
        };
    }

    fn readOpaque(context: *const anyopaque, buf: []u8) anyerror!usize {
        var self: *FileOffsetReader = @constCast(@ptrCast(@alignCast(context)));
        return self.read(buf);
    }
};

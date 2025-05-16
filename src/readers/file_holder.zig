const std = @import("std");
const fs = std.fs;
const io = std.io;

pub const FileHolder = struct {
    file: fs.File,
    offset: u64,

    pub fn init(path: []const u8, offset: u64) !FileHolder {
        const fil = try fs.cwd().openFile(path, .{});
        return .{
            .file = fil,
            .offset = offset,
        };
    }
    pub fn deinit(self: FileHolder) void {
        self.file.close();
    }

    pub fn anyAt(self: FileHolder, offset: u64) io.AnyReader {
        var offsetRdr = FileOffsetReader{
            .file = self.file,
            .offset = self.offset + offset,
        };
        return offsetRdr.any();
    }
};

const FileOffsetReader = struct {
    file: fs.File,
    offset: u64,

    fn read(self: *FileOffsetReader, bytes: []u8) !usize {
        const red = try self.file.pread(bytes, self.offset);
        self.offset += red;
        return red;
    }
    fn any(self: *FileOffsetReader) io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = readOpaque,
        };
    }
    fn readOpaque(context: *const anyopaque, bytes: []u8) !usize {
        var rdr: *FileOffsetReader = @constCast(@ptrCast(@alignCast(context)));
        return try rdr.read(bytes);
    }
};

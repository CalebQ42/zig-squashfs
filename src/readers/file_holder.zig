const std = @import("std");
const fs = std.fs;
const io = std.io;

const File = std.fs.File;

pub const FileHolder = struct {
    file: File,
    offset: u64,

    pub fn init(path: []const u8, offset: u64) !FileHolder {
        return .{
            .file = try fs.cwd().openFile(path, .{ .mode = .read_write }),
            .offset = offset,
        };
    }
    pub fn deinit(self: FileHolder) void {
        self.file.close();
    }

    pub fn reader(self: *FileHolder) File.Reader {
        return self.file.reader();
    }
    pub fn readerAt(self: *FileHolder, offset: u64) FileOffsetReader {
        return .{
            .file = &self.file,
            .offset = self.offset + offset,
        };
    }
};

const FileOffsetReader = struct {
    file: *File,
    offset: u64,

    pub fn read(self: *FileOffsetReader, bytes: []u8) !usize {
        const red = try self.file.preadAll(bytes, self.offset);
        self.offset += red;
        return red;
    }
    pub fn any(self: *FileOffsetReader) io.AnyReader {
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

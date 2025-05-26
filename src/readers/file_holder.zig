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

    // pub fn writerAt(self: *FileHolder, offset: u64) FileOffsetWriter {
    //     return .{
    //         .file = &self.file,
    //         .offset = self.offset + offset,
    //     };
    // }
};

pub const FileOffsetWriter = struct {
    file: *File,
    offset: u64,

    pub fn init(fil: *File, init_offset: u64) FileOffsetWriter {
        return .{
            .file = fil,
            .offset = init_offset,
        };
    }

    pub const Error = fs.File.PWriteError;

    pub fn write(self: *FileOffsetWriter, bytes: []const u8) !usize {
        try self.file.pwriteAll(bytes, self.offset);
        self.offset += bytes.len;
        return bytes.len;
    }
    pub fn any(self: *FileOffsetWriter) io.AnyWriter {
        return .{
            .context = @ptrCast(self),
            .writeFn = writeOpaque,
        };
    }
    fn writeOpaque(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        var rdr: *FileOffsetWriter = @constCast(@ptrCast(@alignCast(context)));
        return try rdr.write(bytes);
    }
};

pub const FileOffsetReader = struct {
    file: *File,
    offset: u64,

    pub const Error = fs.File.PReadError;

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

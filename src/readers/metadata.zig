const std = @import("std");
const io = std.io;

const DecompressType = @import("../decompress.zig").DecompressType;

const MetadataHeader = packed struct {
    size: u15,
    not_compressed: bool,
};

pub const MetadataReader = struct {
    alloc: std.mem.Allocator,
    decomp: DecompressType,
    reader: io.AnyReader,
    block: []u8 = &[0]u8{},
    offset: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, decomp: DecompressType, rdr: io.AnyReader) MetadataReader {
        return .{
            .alloc = alloc,
            .decomp = decomp,
            .reader = rdr,
        };
    }
    pub fn deinit(self: *MetadataReader) void {
        self.alloc.free(self.block);
    }

    pub fn skip(self: *MetadataReader, offset: u16) !void {
        var cur_skip: u32 = 0;
        var to_skip: u32 = 0;
        while (cur_skip < offset) {
            if (self.offset >= self.block.len) try self.readNextBlock();
            to_skip = @min(offset - cur_skip, self.block.len - self.offset);
            cur_skip += to_skip;
            self.offset += to_skip;
        }
    }

    fn readNextBlock(self: *MetadataReader) !void {
        self.offset = 0;
        if (self.block.len > 0) self.alloc.free(self.block);
        const hdr = try self.reader.readStruct(MetadataHeader);
        if (hdr.not_compressed) {
            self.block = try self.alloc.alloc(u8, hdr.size);
            _ = try self.reader.readAll(self.block);
        } else {
            var limit = std.io.limitedReader(self.reader, hdr.size);
            var dat = try self.decomp.decompress(self.alloc, limit.reader().any());
            self.block = try dat.toOwnedSlice();
        }
    }

    pub fn any(self: *MetadataReader) io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = readOpaque,
        };
    }

    pub fn read(self: *MetadataReader, bytes: []u8) !usize {
        var cur_read: usize = 0;
        var to_read: usize = 0;
        while (cur_read < bytes.len) {
            if (self.offset >= self.block.len) try self.readNextBlock();
            to_read = @min(bytes.len - cur_read, self.block.len - self.offset);
            @memcpy(bytes[cur_read .. cur_read + to_read], self.block[self.offset .. @as(usize, self.offset) + to_read]);
            self.offset += @truncate(to_read);
            cur_read += to_read;
        }
        return cur_read;
    }
    fn readOpaque(context: *const anyopaque, bytes: []u8) !usize {
        var rdr: *MetadataReader = @constCast(@ptrCast(@alignCast(context)));
        return rdr.read(bytes);
    }
};

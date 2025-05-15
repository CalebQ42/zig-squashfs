const std = @import("std");
const io = std.io;

const CompressionType = @import("decompress.zig").CompressionType;

pub const MetadataHeader = packed struct {
    size: u15,
    not_compressed: bool,
};

pub const MetadataReader = struct {
    rdr: std.io.AnyReader,
    alloc: std.mem.Allocator,
    decomp: CompressionType,
    curBlock: []u8,
    curOffset: u16,
    free: bool = false,

    pub fn init(decomp: CompressionType, rdr: io.AnyReader, alloc: std.mem.Allocator) !MetadataReader {
        var out: MetadataReader = .{
            .rdr = rdr,
            .alloc = alloc,
            .decomp = decomp,
            .curBlock = &[_]u8{},
            .curOffset = 0,
        };
        try out.readNextBlock();
        return out;
    }
    pub fn deinit(self: *MetadataReader) void {
        self.alloc.free(self.curBlock);
    }
    pub fn any(self: *MetadataReader) io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = readOpaque,
        };
    }
    pub fn skip(self: *MetadataReader, offset: u16) !void {
        var to_skip = offset;
        var cur_left = self.curBlock.len - self.curOffset;
        while (to_skip > cur_left) {
            to_skip -= @intCast(cur_left);
            try self.readNextBlock();
            cur_left = self.curBlock.len;
        }
        self.curOffset = to_skip;
    }

    fn readNextBlock(self: *MetadataReader) !void {
        if (self.curBlock.len != 0) {
            self.alloc.free(self.curBlock);
        }
        self.curOffset = 0;
        const hdr = try self.rdr.readStruct(MetadataHeader);
        if (hdr.not_compressed) {
            self.curBlock = try self.alloc.alloc(u8, hdr.size);
            _ = try self.rdr.readAll(self.curBlock);
        } else {
            var limit_rdr = std.io.limitedReader(self.rdr, hdr.size);
            self.curBlock = try self.decomp.Decompress(self.alloc, limit_rdr.reader().any());
        }
    }

    pub fn read(self: *MetadataReader, bytes: []u8) anyerror!usize {
        var cur_read: usize = 0;
        var to_read: usize = 0;
        while (cur_read < bytes.len) {
            if (self.curOffset + 1 == self.curBlock.len) {
                try self.readNextBlock();
            }
            to_read = @min(bytes.len - cur_read, self.curBlock.len - self.curOffset);
            std.mem.copyForwards(u8, bytes[cur_read..], self.curBlock[self.curOffset .. self.curOffset + to_read]);
            self.curOffset += @truncate(to_read);
            cur_read += to_read;
        }
        return cur_read;
    }

    fn readOpaque(context: *const anyopaque, bytes: []u8) anyerror!usize {
        var self: *MetadataReader = @constCast(@ptrCast(@alignCast(context)));
        return self.read(bytes);
    }
};

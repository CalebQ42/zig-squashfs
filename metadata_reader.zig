const std = @import("std");
const io = std.io;

const MetadataHeader = packed struct {
    not_compressed: bool,
    size: u15,
};

const MetadataReader = struct {
    rdr: std.io.AnyReader,
    alloc: std.heap.Allocator,
    curBlock: []const u8,
    curOffset: u16,

    pub fn init(rdr: io.AnyReader, alloc: std.heap.Allocator) !MetadataReader {
        const out = .{
            .rdr = rdr,
            .alloc = alloc,
            .curBlock = undefined,
            .curOffset = 0,
        };
        try out.readNextBlock();
        return out;
    }
    pub fn any(self: MetadataReader) !io.AnyReader {
        return .{
            .context = @ptrCast(&self),
            .readFn = typeErasedReadFn,
        };
    }

    fn readNextBlock(self: MetadataReader) !void {
        if (self.curBlock != undefined) {
            self.alloc.free(self.curBlock);
        }
        self.curOffset = 0;
        const hdr = try self.rdr.readStruct(MetadataHeader);
        const buf = try self.alloc.alloc(u8, hdr.size);
        if (hdr.not_compressed) {
            self.curBlock = buf;
        } else {
            //TODO: decompress
        }
    }
};

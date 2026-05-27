const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Limit = Io.Limit;

const DecompCache = @import("decomp_cache.zig");

const MetadataReader = @This();

const BlockHeader = packed struct(u16) {
    size: u15,
    uncompressed: bool,
};

io: Io,

cur_offset: u64 = 0,
next_offset: u64,

cache: *DecompCache,

interface: Reader = .{
    .buffer = &[0]u8{},
    .end = 0,
    .seek = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(io: Io, cache: *DecompCache, offset: u64) void {
    return .{
        .io = io,

        .next_offset = offset,

        .cache = cache,
    };
}
pub fn deinit(self: *MetadataReader) void {
    if (self.cur_block_offset != 0)
        self.cache.checkinBlock(self.io, self.cur_block_offset);
}

fn advance(self: *MetadataReader) !void {
    if (self.interface.buffer.len > 0)
        self.cache.checkinBlock(self.io, self.cur_offset);
    const hdr = std.mem.readInt(BlockHeader, self.cache.map[self.next_offset..][0..2], .little);
    self.cur_offset = self.next_offset + 2;
    self.next_offset += hdr.size;
    if (hdr.uncompressed) {
        self.interface.buffer = self.cache.map[self.cur_offset..][0..hdr.size];
        self.interface.end = hdr.size;
        self.interface.seek = 0;
        return;
    }
    self.interface.buffer = try self.cache.checkoutBlock(self.io, self.cur_offset, hdr.size, 8192);
    self.interface.end = self.interface.buffer.len;
    self.interface.seek = 0;
}

fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {}
fn discard(r: *Reader, limit: Limit) Reader.Error!usize {}
fn readVec(r: *Reader, vec: [][]u8) Reader.Error!usize {}

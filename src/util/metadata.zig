//! A cache for decompressed blocks. Used for Metadata & fragments.

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

pub fn init(io: Io, cache: *DecompCache, offset: u64) MetadataReader {
    return .{
        .io = io,

        .next_offset = offset,

        .cache = cache,
    };
}
pub fn deinit(self: *MetadataReader) void {
    if (self.cur_offset != 0)
        self.cache.checkinBlock(self.io, self.cur_offset);
}

fn advance(self: *MetadataReader) !void {
    if (self.interface.buffer.len > 0)
        self.cache.checkinBlock(self.io, self.cur_offset);
    const hdr: BlockHeader = @bitCast(std.mem.readInt(u16, self.cache.map.memory[self.next_offset..][0..2], .little));
    self.cur_offset = self.next_offset + 2;
    self.next_offset += hdr.size;
    if (hdr.uncompressed) {
        self.interface.buffer = self.cache.map.memory[self.cur_offset..][0..hdr.size];
        self.interface.end = hdr.size;
        self.interface.seek = 0;
        return;
    }
    self.interface.buffer = try self.cache.checkoutBlock(self.io, self.cur_offset, hdr.size, 8192);
    self.interface.end = self.interface.buffer.len;
    self.interface.seek = 0;
}

fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
    if (r.seek == r.end) {
        var self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch return Reader.Error.ReadFailed;
    }
    if (limit == .nothing) return 0;
    const to_write = @min(r.end - r.seek, @intFromEnum(limit));
    const wrote = try w.write(r.buffer[r.seek..][0..to_write]);
    r.seek += wrote;
    return wrote;
}
fn discard(r: *Reader, limit: Limit) Reader.Error!usize {
    if (r.seek == r.end) {
        var self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch return Reader.Error.ReadFailed;
    }
    if (limit == .nothing) return 0;
    const to_skip = @min(r.end - r.seek, @intFromEnum(limit));
    r.seek += to_skip;
    return to_skip;
}
fn readVec(r: *Reader, vec: [][]u8) Reader.Error!usize {
    if (r.seek == r.end) {
        var self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch return Reader.Error.ReadFailed;
    }
    if (vec.len == 0) return 0;
    var total_copied: usize = 0;
    for (vec) |v| {
        const to_cpy = @min(r.end - r.seek, v.len);
        @memcpy(v[0..to_cpy], r.buffer[r.seek..][0..to_cpy]);
        r.seek += to_cpy;
        total_copied += to_cpy;
        if (r.seek == r.end) break;
    }
    return total_copied;
}

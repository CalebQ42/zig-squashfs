const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Limit = Io.Limit;

const DecompCache = @import("decomp_cache.zig");

const MetadataReader = @This();

io: Io,
cache: *DecompCache,

cur_offset: u64 = 0,
next_offset: u64,

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

pub fn init(io: Io, cache: *DecompCache, start: u64) MetadataReader {
    return .{
        .io = io,
        .cache = cache,

        .next_offset = start,
    };
}
pub fn deinit(self: *MetadataReader, io: Io) void {
    self.cache.finished(io, self.cur_offset);
}

fn advance(self: *MetadataReader) !void {
    self.cache.finished(self.io, self.cur_offset);

    self.interface.seek = 0;
    errdefer self.interface.end = 0;

    const hdr: Header = @bitCast(std.mem.readInt(u16, self.cache.map.memory[self.next_offset..][0..2], .little));
    self.cur_offset = self.next_offset + 2;
    self.next_offset = self.cur_offset + hdr.size;

    if (hdr.uncompressed) {
        self.interface.buffer = self.cache.map.memory[self.cur_offset..][0..hdr.size];
        self.interface.end = hdr.size;
        return;
    }
    self.interface.buffer = try self.cache.get(self.io, self.cur_offset, hdr.size, 8192);
    self.interface.end = self.interface.buffer.len;
}

fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch |err| {
            std.debug.print("error advancing metadata reader: {}\n", .{err});
            return Reader.Error.ReadFailed;
        };
    }
    const to_write = @min(r.end - r.seek, @intFromEnum(limit));
    const wrote = try w.write(r.buffer[r.seek..][0..to_write]);
    r.seek += wrote;
    return wrote;
}
fn discard(r: *Reader, limit: Limit) Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch |err| {
            std.debug.print("error advancing metadata reader: {}\n", .{err});
            return Reader.Error.ReadFailed;
        };
    }
    const to_discard = @min(r.end - r.seek, @intFromEnum(limit));
    r.seek += to_discard;
    return to_discard;
}
fn readVec(r: *Reader, vec: [][]u8) Reader.Error!usize {
    if (r.seek >= r.end) {
        const self: *MetadataReader = @fieldParentPtr("interface", r);
        self.advance() catch |err| {
            std.debug.print("error advancing metadata reader: {}\n", .{err});
            return Reader.Error.ReadFailed;
        };
    }
    var total: usize = 0;
    for (vec) |v| {
        const to_copy = @min(r.end - r.seek, v.len);
        @memcpy(v[0..to_copy], r.buffer[r.seek..][0..to_copy]);
        r.seek += to_copy;
        total += to_copy;
        if (r.seek >= r.end)
            break;
    }
    return total;
}

// Types

const Header = packed struct(u16) {
    size: u15,
    uncompressed: bool,
};

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

const Decompressor = @import("../decomp.zig");

const Header = packed struct {
    size: u15,
    uncompressed: bool,
};

const MetadataReader = @This();

rdr: *Reader,
decomp: *const Decompressor,

read_buf: [8192]u8 = undefined,
interface: Reader = .{
    .buffer = &([1]u8{undefined} ** 8192),
    .end = 0,
    .seek = 0,
    .vtable = &.{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
    },
},

pub fn init(rdr: *Reader, decomp: *const Decompressor) MetadataReader {
    return .{ .rdr = rdr, .decomp = decomp };
}
fn advanceBuffer(self: *MetadataReader) Reader.Error!void {
    self.interface.seek = 0;
    var hdr: Header = undefined;
    try self.rdr.readSliceEndian(Header, @ptrCast(&hdr), .little);
    try self.rdr.readSliceAll(self.read_buf[0..hdr.size]);
    if (hdr.uncompressed) {
        @memcpy(self.interface.buffer[0..hdr.size], self.read_buf[0..hdr.size]);
        self.interface.end = hdr.size;
        return;
    }
    self.interface.end = self.decomp.decompress(self.read_buf[0..hdr.size], self.interface.buffer) catch |err| return switch (err) {
        error.OutOfMemory => error.ReadFailed,
        else => err,
    };
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) Reader.StreamError!usize {
    var self: *MetadataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end) try self.advanceBuffer();
    const to_write = @min(@intFromEnum(limit), rdr.end - rdr.seek);
    const wrote = try wrt.write(rdr.buffer[rdr.seek .. rdr.seek + to_write]);
    rdr.seek += wrote;
    return wrote;
}
fn discard(rdr: *Reader, limit: Limit) Reader.Error!usize {
    var self: *MetadataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end) try self.advanceBuffer();
    const to_adv = @min(@intFromEnum(limit), rdr.end - rdr.seek);
    rdr.seek += to_adv;
    return to_adv;
}
fn readVec(rdr: *Reader, vec: [][]u8) Reader.Error!usize {
    var self: *MetadataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek == rdr.end) try self.advanceBuffer();
    var wrote = 0;
    for (vec) |v| {
        if (rdr.seek == rdr.end) break;
        const to_write = @min(v.len, rdr.end - rdr.seek);
        @memcpy(v[0..to_write], rdr.buffer[rdr.seek .. rdr.seek + to_write]);
        wrote += to_write;
        rdr.seek += to_write;
    }
    return wrote;
}

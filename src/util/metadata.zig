const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;
const StreamError = std.Io.Reader.StreamError;

const DecompFn = @import("../decomp.zig").DecompFn;

const BlockHeader = packed struct {
    size: u15,
    uncompressed: bool,
};

const This = @This();

alloc: std.mem.Allocator,
rdr: *Reader,
decomp: DecompFn,

buf: [8192]u8 = undefined,

interface: Reader,
err: ?anyerror = null,

pub fn init(alloc: std.mem.Allocator, rdr: *Reader, decomp: DecompFn) This {
    return .{
        .alloc = alloc,
        .rdr = rdr,
        .decomp = decomp,
        .interface = .{
            .buffer = &[0]u8{},
            .end = 0,
            .seek = 0,
            .vtable = &.{
                .stream = stream,
                .discard = discard,
                .readVec = readVec,
            },
        },
    };
}

fn advance(self: *This) !void {
    self.interface.seek = 0;
    var hdr: BlockHeader = undefined;
    try self.rdr.readSliceEndian(BlockHeader, @ptrCast(&hdr), .little);
    if (hdr.uncompressed) {
        try self.rdr.readSliceEndian(u8, self.buf[0..hdr.size], .little);
        self.interface.end = hdr.size;
        self.interface.buffer = self.buf[0..hdr.size];
        return;
    }
    var tmp_buf: [8192]u8 = undefined;
    try self.rdr.readSliceAll(tmp_buf[0..hdr.size]);
    self.interface.end = try self.decomp(self.alloc, tmp_buf[0..hdr.size], &self.buf);
    self.interface.buffer = self.buf[0..self.interface.end];
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) StreamError!usize {
    const self: *This = @fieldParentPtr("interface", rdr);
    if (rdr.end == rdr.seek) self.advance() catch |err| {
        self.err = err;
        return StreamError.ReadFailed;
    };
    if (@intFromEnum(limit) == 0) return 0;
    const to_write = @min(rdr.end - rdr.seek, @intFromEnum(limit));
    const wrote = try wrt.write(self.buf[rdr.seek .. rdr.seek + to_write]);
    self.interface.seek += wrote;
    return wrote;
}
fn discard(rdr: *Reader, limit: Limit) error{ EndOfStream, ReadFailed }!usize {
    const self: *This = @fieldParentPtr("interface", rdr);
    if (rdr.end == rdr.seek) self.advance() catch |err| {
        self.err = err;
        return StreamError.ReadFailed;
    };
    if (@intFromEnum(limit) == 0) return 0;
    const to_skip = @min(rdr.end - rdr.seek, @intFromEnum(limit));
    rdr.seek += to_skip;
    return to_skip;
}
fn readVec(rdr: *Reader, vec: [][]u8) error{ EndOfStream, ReadFailed }!usize {
    const self: *This = @fieldParentPtr("interface", rdr);
    if (rdr.end == rdr.seek) self.advance() catch |err| {
        self.err = err;
        return StreamError.ReadFailed;
    };
    var cur_red: usize = 0;
    for (vec) |s| {
        const to_copy: usize = @min(rdr.end - rdr.seek, s.len);
        @memcpy(s[0..to_copy], self.buf[rdr.seek .. rdr.seek + to_copy]);
        rdr.seek += to_copy;
        cur_red += to_copy;
        if (rdr.end == rdr.seek) break;
    }
    return cur_red;
}

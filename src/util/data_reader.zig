const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

const FragEntry = @import("../archive.zig").FragEntry;
const Decompressor = @import("../decomp.zig");
const BlockSize = @import("../inode/file.zig").BlockSize;
const OffsetFile = @import("offset_file.zig");

const DataReader = @This();

decomp: *const Decompressor,
file: OffsetFile,
block_size: u32,
blocks: []BlockSize,
size: u64,
frag: ?FragEntry,
frag_offset: u32,

offset: u64,
idx: usize = 0,
sparse: bool = false,

interface: Reader,

pub fn init(decomp: *const Decompressor, file: OffsetFile, block_size: u32, blocks: []BlockSize, size: u64, init_offset: u64, frag: ?FragEntry, frag_offset: u32) DataReader {
    return .{
        .decomp = decomp,
        .file = file,
        .block_size = block_size,
        .blocks = blocks,
        .size = size,
        .frag = frag,
        .frag_offset = frag_offset,

        .offset = init_offset,

        .interface = .{
            .buffer = &[1]u8{undefined} ** (1024 * 1024),
            .end = 0,
            .seek = 0,
            .vtable = &.{ .stream = stream, .discard = discard, .readVec = readVec },
        },
    };
}

fn numBlocks(self: *DataReader) usize {
    return if (self.frag == null)
        self.blocks.len
    else
        self.blocks.len + 1;
}
fn advanceBuffer(self: *DataReader) Reader.Error!void {
    if (self.idx >= self.numBlocks()) return Reader.Error.EndOfStream;
    defer self.idx += 1;
    self.sparse = false;
    self.interface.end = 0; // If we error out and the error is ignored, we'll stil end up back here to error again.
    self.interface.seek = 0;
    if (self.idx == self.blocks.len) { // Fragment
        var rdr = self.file.readerAt(self.frag.?.block_start, &[0]u8{}) catch return Reader.Error.ReadFailed;
        const size = self.size % self.block_size;
        if (self.frag.?.size.uncompressed) {
            try rdr.interface.discardAll(self.frag_offset);
            try rdr.interface.readSliceAll(self.interface.buffer[0..size]);
            self.interface.end = size;
            return;
        }
        const raw_loc = self.interface.buffer.len - self.frag.?.size.size;
        try rdr.interface.readSliceAll(self.interface.buffer[raw_loc..]);
        _ = self.decomp.decompress(self.interface.buffer[raw_loc..], self.interface.buffer) catch
            return Reader.Error.ReadFailed;
        @memmove(self.interface.buffer[0..size], self.interface.buffer[self.frag_offset .. self.frag_offset + size]);
        self.interface.end = size;
        return;
    }
    const block = self.blocks[self.idx];
    if (block.size == 0) {
        self.interface.end = if (self.idx == self.numBlocks() - 1)
            self.size % self.block_size
        else
            self.block_size;
        self.sparse = true;
        return;
    }
    defer self.offset += block.size;
    var rdr = try self.file.readerAt(self.offset, &[0]u8{});
    if (block.uncompressed) {
        try rdr.interface.readSliceAll(self.interface.buffer[0..block.size]);
        self.interface.end = block.size;
        return;
    }
    const raw_loc = self.interface.buffer.len - block.size;
    try rdr.interface.readSliceAll(self.interface.buffer[raw_loc..]);
    self.interface.end = self.decomp.decompress(self.interface.buffer[raw_loc..], self.interface.buffer) catch
        return Reader.Error.ReadFailed;
}

fn stream(r: *Reader, wrt: *Writer, limit: Limit) Reader.StreamError!usize {
    var self: *DataReader = @fieldParentPtr("interface", r);
    if (r.seek == r.end) try self.advanceBuffer();
    if (limit == .nothing) return 0;

    const to_write = @min(r.end - r.seek, @intFromEnum(limit));
    const wrote = if (self.sparse)
        try wrt.splatByte(0, to_write)
    else
        try wrt.write(r.buffer[r.seek .. r.seek + to_write]);
    r.seek += wrote;
    return wrote;
}
fn discard(r: *Reader, limit: Limit) Reader.Error!usize {
    var self: *DataReader = @fieldParentPtr("interface", r);
    if (r.seek == r.end) try self.advanceBuffer();
    if (limit == .nothing) return 0;

    const adv = @min(r.end - r.seek, @intFromEnum(limit));
    r.seek += adv;
    return adv;
}
fn readVec(r: *Reader, vec: [][]u8) Reader.Error!usize {
    var self: *DataReader = @fieldParentPtr("interface", r);
    if (r.seek == r.end) try self.advanceBuffer();

    var wrote: usize = 0;
    for (vec) |slice| {
        if (r.seek == r.end) break;
        const to_copy = @min(r.end - r.seek, slice.len);
        if (self.sparse) {
            @memset(slice[0..to_copy], 0);
        } else {
            @memcpy(slice[0..to_copy], r.buffer[r.seek .. r.seek + to_copy]);
        }
        r.seek += to_copy;
        wrote += to_copy;
    }
    return wrote;
}

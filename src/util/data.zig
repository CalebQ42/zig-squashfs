//! A reader for a regular file.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

const Archive = @import("../archive.zig");
const FragEntry = Archive.FragEntry;
const DecompMgr = @import("../decomp.zig");
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const OffsetFile = @import("offset_file.zig");

const DataReader = @This();

alloc: std.mem.Allocator,
fil: OffsetFile,
decomp: *DecompMgr,
block_size: u32,

blocks: []BlockSize,

frag: ?FragEntry = null, // TODO: do something better?
frag_offset: u32 = 0,
size: u64,

interface: Reader,

cur_offset: u64,
block_idx: u32 = 0,

pub fn init(archive: *Archive, blocks: []BlockSize, start: u64, size: u64) DataReader {
    return .{
        .alloc = archive.allocator(),
        .fil = archive.fil,
        .decomp = &archive.decomp,
        .block_size = archive.super.block_size,
        .blocks = blocks,
        .size = size,
        .cur_offset = start,
        .interface = .{
            .end = 0,
            .seek = 0,
            .buffer = &[0]u8{},
            .vtable = &.{
                .stream = stream,
                .discard = discard,
                .readVec = readVec,
            },
        },
    };
}
pub fn deinit(self: *DataReader) void {
    self.alloc.free(self.interface.buffer);
    self.interface.end = 0;
    self.interface.seek = 0;
}

pub fn addFragment(self: *DataReader, entry: FragEntry, frag_offset: u32) void {
    self.frag = entry;
    self.frag_offset = frag_offset;
}

fn numBlocks(self: DataReader) usize {
    var res = self.blocks.len;
    if (self.frag != null) res += 1;
    return res;
}

fn advance(self: *DataReader) !void {
    if (self.block_idx > self.blocks.len or (self.block_idx == self.blocks.len and self.frag == null)) {
        if (self.interface.buffer.len > 0) {
            self.alloc.free(self.interface.buffer);
            self.interface.buffer = &[0]u8{};
            self.interface.end = 0;
            self.interface.seek = 0;
        }
        return Reader.Error.EndOfStream;
    }
    defer self.block_idx += 1;
    const cur_block_size = if (self.block_idx == self.numBlocks() - 1) self.size % self.block_size else self.block_size;
    try self.resizeBuffer(cur_block_size);
    self.interface.seek = 0;
    self.interface.end = cur_block_size;
    if (self.block_idx == self.blocks.len) { // fragment
        var rdr = try self.fil.readerAt(self.frag.?.start, &[0]u8{});
        if (self.frag.?.size.uncompressed) {
            try rdr.interface.discardAll(self.frag_offset);
            try rdr.interface.readSliceAll(self.interface.buffer);
            return;
        }
        const tmp_buf = try self.alloc.alloc(u8, self.frag.?.size.size);
        defer self.alloc.free(tmp_buf);
        var limit_rdr = Reader.limited(&rdr.interface, @enumFromInt(self.frag.?.size.size), tmp_buf);
        const needed_block = try self.alloc.alloc(u8, self.frag_offset + cur_block_size);
        defer self.alloc.free(needed_block);
        _ = try self.decomp.decompReader(&limit_rdr.interface, needed_block);
        @memcpy(self.interface.buffer, needed_block[self.frag_offset..]);
        return;
    }
    const block = self.blocks[self.block_idx];
    if (block.size == 0) {
        @memset(self.interface.buffer, 0);
        return;
    }
    var rdr = try self.fil.readerAt(self.cur_offset, &[0]u8{});
    if (block.uncompressed) {
        try rdr.interface.readSliceAll(self.interface.buffer);
        return;
    }
    var buf: [8192]u8 = undefined; //TODO: possibly change for better performance/memory usage. Might need to be a full block in size.
    var limit_rdr = Reader.limited(&rdr.interface, @enumFromInt(block.size), &buf);
    _ = try self.decomp.decompReader(&limit_rdr.interface, self.interface.buffer);
}
/// Does not guarentee that data currently in the buffer is retained.
fn resizeBuffer(self: *DataReader, size: usize) !void {
    if (self.interface.buffer.len == size) return;
    if (!self.alloc.resize(self.interface.buffer, size)) {
        self.alloc.free(self.interface.buffer);
        self.interface.buffer = self.alloc.alloc(u8, size) catch |err| {
            self.interface.buffer = &[0]u8{};
            return err;
        };
    } else {
        self.interface.buffer.len = size;
    }
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) Reader.StreamError!usize {
    var self: *DataReader = @alignCast(@fieldParentPtr("interface", rdr));
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        std.log.err("Error advancing data reader: {}\n", .{err});
        return Reader.Error.ReadFailed;
    };
    if (limit == .nothing) return 0;
    const to_read = @min(rdr.end - rdr.seek, @intFromEnum(limit));
    const res = try wrt.write(rdr.buffer[rdr.seek .. rdr.seek + to_read]);
    rdr.seek += res;
    return res;
}

fn discard(rdr: *Reader, limit: Limit) Reader.Error!usize {
    var self: *DataReader = @alignCast(@fieldParentPtr("interface", rdr));
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        std.log.err("Error advancing data reader: {}\n", .{err});
        return Reader.Error.ReadFailed;
    };
    if (limit == .nothing) return 0;
    const to_adv = @min(rdr.end - rdr.seek, @intFromEnum(limit));
    rdr.seek += to_adv;
    return to_adv;
}

fn readVec(rdr: *Reader, vec: [][]u8) Reader.Error!usize {
    var self: *DataReader = @alignCast(@fieldParentPtr("interface", rdr));
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        std.log.err("Error advancing data reader: {}\n", .{err});
        return Reader.Error.ReadFailed;
    };
    var cur_red: usize = 0;
    for (vec) |s| {
        const to_copy: usize = @min(rdr.end - rdr.seek, s.len);
        @memcpy(s[0..to_copy], rdr.buffer[rdr.seek .. rdr.seek + to_copy]);
        rdr.seek += to_copy;
        cur_red += to_copy;
        if (rdr.end == rdr.seek) break;
    }
    return cur_red;
}

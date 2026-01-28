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

frag: ?FragEntry, // TODO: do something better?
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
    self.alloc.free(self.inteface.buffer);
}

pub fn addFragment(self: *DataReader, entry: FragEntry, frag_offset: u32) void {
    self.frag = entry;
    self.frag_offset = frag_offset;
}

fn blockNum(self: DataReader) u32 {
    var res = self.blocks.len;
    if (self.frag != null) res += 1;
    return res;
}

fn advance(self: *DataReader) !void {
    if (self.block_idx > self.blocks.len) return Reader.Error.EndOfStream;
    defer self.block_idx += 1;
    self.interface.seek = 0;
    self.alloc.free(self.interface.buffer);
    const cur_block_size = if (self.block_idx == self.blockNum() - 1) self.size % self.block_size else self.block_size;
    if (self.block_idx == self.blocks.len) {
        if (self.frag == null) return Reader.Error.EndOfStream;
        // TODO: Fragment
        return error.TODO;
    }
    const block = self.blocks[self.block_idx];
    if (block.uncompressed) {
        var rdr = try self.fil.readerAt(self.cur_offset, &[0]u8);
        self.interface.buffer = try rdr.interface.readAlloc(self.alloc, cur_block_size);
        self.interface.end = self.interface.buffer.len;
        return;
    }
    return error.TODO;
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) Reader.StreamError!usize {
    var self: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == .EndOfStream) return err;
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
    var self: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == .EndOfStream) return err;
        std.log.err("Error advancing data reader: {}\n", .{err});
        return Reader.Error.ReadFailed;
    };
    if (limit == .nothing) return 0;
    const to_adv = @min(rdr.end - rdr.seek, @intFromEnum(limit));
    rdr.seek += to_adv;
    return to_adv;
}

fn readVec(rdr: *Reader, vec: [][]u8) Reader.Error!usize {
    var self: *DataReader = @fieldParentPtr("interface", rdr);
    if (rdr.seek >= rdr.end) self.advance() catch |err| {
        if (err == .EndOfStream) return err;
        std.log.err("Error advancing data reader: {}\n", .{err});
        return Reader.Error.ReadFailed;
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

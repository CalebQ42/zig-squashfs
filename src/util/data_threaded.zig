//! Similiar to DataReader, but set-up for threaded writing to files.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;
const WaitGroup = std.Thread.WaitGroup;
const Pool = std.Thread.Pool;

const Archive = @import("../archive.zig");
const FragEntry = Archive.FragEntry;
const DecompFn = @import("../decomp.zig").DecompFn;
const BlockSize = @import("../inode_data/file.zig").BlockSize;
const OffsetFile = @import("offset_file.zig");

const ThreadedDataReader = @This();

alloc: std.mem.Allocator,
fil: OffsetFile,
decomp: DecompFn,
block_size: u32,

blocks: []BlockSize,

frag: ?FragEntry = null, // TODO: do something better?
frag_offset: u32 = 0,
size: u64,

start_offset: u64,

pub fn init(alloc: std.mem.Allocator, archive: Archive, blocks: []BlockSize, start: u64, size: u64) ThreadedDataReader {
    return .{
        .alloc = alloc,
        .fil = archive.fil,
        .decomp = archive.decomp,
        .block_size = archive.super.block_size,
        .blocks = blocks,
        .size = size,
        .start_offset = start,
    };
}

pub fn addFragment(self: *ThreadedDataReader, entry: FragEntry, frag_offset: u32) void {
    self.frag = entry;
    self.frag_offset = frag_offset;
}

fn numBlocks(self: ThreadedDataReader) usize {
    var res = self.blocks.len;
    if (self.frag != null) res += 1;
    return res;
}

/// Extract the data to the file threadedly, using pool to spawn threads.
/// If multiple errors occur, thread spawning errors will have, then the last decompression error that occurs;
///
/// The function must be called from an unused DataReader. The DataReader is still usable afterwards.
/// If only extractThreaded is used, there is no need to call deinit() afterwards.
///
/// The file will always be written to starting at 0.
pub fn extractThreaded(self: ThreadedDataReader, file: std.fs.File, pool: *Pool) !void {
    var wg: WaitGroup = .{};
    wg.startMany(self.numBlocks());
    var out_err: ?anyerror = null;

    var cur_write_offset: u64 = 0;
    var cur_read_offset: u64 = self.start_offset;
    for (0..self.blocks.len) |i| {
        const cur_block_size = if (i == self.numBlocks() - 1) self.size % self.block_size else self.block_size;
        try pool.spawn(workThreadBlocks, .{ self, file, cur_write_offset, cur_read_offset, self.blocks[i], cur_block_size, &wg, &out_err });
        cur_write_offset += cur_block_size;
        cur_read_offset += self.blocks[i].size;
    }
    if (self.frag != null) {
        try pool.spawn(workThreadFragment, .{ self, file, cur_write_offset, &wg, &out_err });
    }
    pool.waitAndWork(&wg);
    if (out_err != null) return out_err.?;
}

fn workThreadBlocks(self: ThreadedDataReader, fil: std.fs.File, write_offset: u64, read_offset: u64, block: BlockSize, cur_block_size: u64, wg: *WaitGroup, out_err: *?anyerror) void {
    defer wg.finish();
    var wrt = fil.writer(&[0]u8{});
    wrt.seekTo(write_offset) catch |err| {
        out_err.* = err;
        return;
    };
    defer wrt.interface.flush() catch |err| {
        out_err.* = err;
    };
    if (block.size == 0) {
        wrt.interface.splatByteAll(0, cur_block_size) catch |err| {
            out_err.* = err;
            return;
        };
        return;
    }
    var rdr = self.fil.readerAt(read_offset, &[0]u8{}) catch |err| {
        out_err.* = err;
        return;
    };
    if (block.uncompressed) {
        rdr.interface.streamExact(&wrt.interface, block.size) catch |err| {
            out_err.* = err;
            return;
        };
        return;
    }
    // TODO: shared buffers
    const read_buf = self.alloc.alloc(u8, block.size) catch |err| {
        out_err.* = err;
        return;
    };
    defer self.alloc.free(read_buf);
    rdr.interface.readSliceAll(read_buf) catch |err| {
        out_err.* = err;
        return;
    };
    // TODO: shared buffers
    const res_buf = self.alloc.alloc(u8, cur_block_size) catch |err| {
        out_err.* = err;
        return;
    };
    defer self.alloc.free(res_buf);
    _ = self.decomp(self.alloc, read_buf, res_buf) catch |err| {
        out_err.* = err;
        return;
    };
    wrt.interface.writeAll(res_buf) catch |err| {
        out_err.* = err;
        return;
    };
}
fn workThreadFragment(self: ThreadedDataReader, fil: std.fs.File, write_offset: u64, wg: *WaitGroup, out_err: *?anyerror) void {
    defer wg.finish();

    var wrt = fil.writer(&[0]u8{});
    wrt.seekTo(write_offset) catch |err| {
        out_err.* = err;
        return;
    };
    defer wrt.interface.flush() catch |err| {
        out_err.* = err;
    };

    var rdr = self.fil.readerAt(self.frag.?.start, &[0]u8{}) catch |err| {
        out_err.* = err;
        return;
    };
    if (self.frag.?.size.uncompressed) {
        rdr.interface.discardAll(self.frag_offset) catch |err| {
            out_err.* = err;
            return;
        };
        rdr.interface.streamExact(&wrt.interface, self.size % self.block_size) catch |err| {
            out_err.* = err;
            return;
        };
        return;
    }
    const tmp_buf = self.alloc.alloc(u8, self.frag.?.size.size) catch |err| {
        out_err.* = err;
        return;
    };
    defer self.alloc.free(tmp_buf);
    rdr.interface.readSliceAll(tmp_buf) catch |err| {
        out_err.* = err;
        return;
    };
    const needed_block = self.alloc.alloc(u8, self.block_size) catch |err| {
        out_err.* = err;
        return;
    };
    defer self.alloc.free(needed_block);
    _ = self.decomp(self.alloc, tmp_buf, needed_block) catch |err| {
        out_err.* = err;
        return;
    };
    wrt.interface.writeAll(needed_block[self.frag_offset .. self.frag_offset + (self.size % self.block_size)]) catch |err| {
        out_err.* = err;
        return;
    };
}

const std = @import("std");
const builtin = @import("builtin");

const SfsReader = @import("../sfs_reader.zig");
const MemPool = @import("../util/mem_pool.zig").MemPool;
const Compressor = @import("../decompress.zig").Compressor;
const DataBlockSize = @import("../inode.zig").DataBlockSize;
const FilePReader = @import("preader.zig").PReader(std.fs.File);

const FullReaderError = error{InvalidIndex};

const Self = @This();

alloc: std.mem.Allocator,
comp: Compressor,
rdr: *FilePReader,
threadPool: *std.Thread.Pool,
memPool: *MemPool(struct { u32, anyerror![]u8 }),

file_size: u64,
block_size: u32,

offsets: []u64,
sizes: []DataBlockSize,
frag_data: []u8 = &[0]u8,

pub fn init(rdr: *SfsReader, file_size: u64, start: u64, sizes: []DataBlockSize) !Self {
    const offsets = try rdr.alloc.alloc(u64, sizes.len);
    var off = start;
    for (0..offsets.len) |i| {
        offsets[i] = off;
        off += sizes[i].size;
    }
    return .{
        .alloc = rdr.alloc,
        .rdr = rdr.rdr,
        .file_size = file_size,
        .block_size = rdr.super.block_size,
        .offsets = offsets,
        .sizes = sizes,
    };
}
pub fn deinit(self: Self) void {
    self.alloc.free(self.frag_data);
}

pub fn addFrag(self: *Self, start: u64, size: DataBlockSize, offset: u32) !void {
    var off_rdr = self.rdr.readerAt(start);
    var dat = try self.alloc.alloc(u8, self.block_size);
    defer self.alloc.free(dat);
    const frag_size = self.sizes % self.block_size;
    self.frag_data = try self.alloc.alloc(u8, frag_size);
    if (size.not_compressed) {
        _ = try off_rdr.readAll(dat[0 .. offset + frag_size]);
        return;
    } else {
        const limit_rdr = std.io.limitedReader(off_rdr, size.size);
        _ = try self.comp.decompress(self.alloc, limit_rdr, dat);
    }
    @memcpy(self.frag_data, dat[offset .. offset + frag_size]);
}

pub fn setPools(self: *Self, thr: *std.Thread.Pool, mem: *MemPool(struct { u32, anyerror![]u8 })) void {
    self.threadPool = thr;
    self.memPool = mem;
}

pub fn block(self: Self, idx: u32) ![]u8 {
    if (idx > self.sizes.len) return FullReaderError.InvalidIndex;
    if (idx == self.sizes.len) {
        if (self.frag_data.len > 0) {
            const dat = try self.alloc.alloc(u8, self.frag_data.len);
            @memcpy(dat, self.frag_data);
            return dat;
        }
        return FullReaderError.InvalidIndex;
    }
    var buf = try self.alloc.alloc(u8, self.block_size);
    errdefer self.alloc.free(buf);
    if (self.sizes[idx].not_compressed) {
        _ = try self.rdr.preadAll(buf, self.offsets[idx]);
        return buf;
    }
    const off_rdr = self.rdr.readerAt(self.offsets[idx]);
    const siz = try self.comp.decompress(self.alloc, off_rdr, buf);
    if (siz == self.block_size) {
        return buf;
    }
    return buf[0..siz];
}

pub fn blockThreaded(self: Self, idx: u32) !void {}

/// Write's the entire file's data to the given writer.
/// If available, pwriteAll will be used, otherwise write will.
pub fn writeTo(self: Self, writer: anytype) !usize {
    comptime std.debug.assert(std.meta.hasFn(writer, "write") or
        std.meta.hasFn(writer, "writeAll") or
        std.meta.hasFn(writer, "pwrite") or
        std.meta.hasFn(writer, "pwriteAll"));
    if (self.threadPool == null) {
        self.threadPool = undefined;
        self.threadPool.init(.{
            .n_jobs = try std.Thread.getCpuCount(),
        });
        self.memPool = .init(self.alloc);
    }
}

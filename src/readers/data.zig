const std = @import("std");

const SfsReader = @import("../sfs_reader.zig");
const Compressor = @import("../decompress.zig").Compressor;
const DataBlockSize = @import("../inode.zig").DataBlockSize;
const FilePReader = @import("preader.zig").PReader(std.fs.File);

const Self = @This();

alloc: std.mem.Allocator,
rdr: *FilePReader,
comp: Compressor,

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

const std = @import("std");

const Inode = @import("../inode.zig");
const PRead = @import("p_read.zig").PRead;
const SfsReader = @import("../reader.zig").SfsReader;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

const DataReaderError = error{
    EOF,
    InvalidIndex,
};

pub fn DataReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        rdr: PRead(T),
        comp: Compression,
        block_size: u32,

        sizes: []BlockSize,
        offsets: []u64,
        file_size: u64,

        frag: ?[]u8 = null,

        pub fn init(rdr: *SfsReader(T), inode: Inode) !Self {
            var sizes: []BlockSize = undefined;
            var file_size: u64 = 0;
            var offsets: []u64 = undefined;
            switch (inode.data) {
                .file => |f| {
                    sizes = f.block_sizes;
                    file_size = f.size;
                    offsets = try rdr.alloc.alloc(u64, sizes.len);
                    if (sizes.len > 0) offsets[0] = f.block;
                },
                .ext_file => |f| {
                    sizes = f.block_sizes;
                    file_size = f.size;
                    offsets = try rdr.alloc.alloc(u64, sizes.len);
                    if (sizes.len > 0) offsets[0] = f.block;
                },
                else => unreachable,
            }
            for (1..offsets.len) |i| {
                offsets[i] = offsets[i - 1] + sizes[i - 1].size;
            }
            return .{
                .alloc = rdr.alloc,
                .rdr = rdr.rdr,
                .comp = rdr.super.comp,
                .block_size = rdr.super.block_size,
                .sizes = sizes,
                .offsets = offsets,
                .files_size = file_size,
            };
        }
        pub fn deinit(self: Self) void {
            self.alloc.free(self.offsets);
        }

        pub fn addFragment(self: Self, data: []u8) void {
            self.frag = data;
        }

        pub fn writeTo(self: Self, wrt: anytype) !void {
            comptime std.debug.assert(std.meta.hasFn(@TypeOf(wrt), "write") or std.meta.hasFn(@TypeOf(wrt), "pwrite"));
        }
        pub fn writeToNoBlock(self: Self, wrt: anytype, comptime finish: anytype, finish_args: anytype) !void {
            comptime std.debug.assert(std.meta.hasFn(@TypeOf(wrt), "write") or std.meta.hasFn(@TypeOf(wrt), "pwrite"));
        }

        fn numBlocks(self: Self) usize {
            var out = self.sizes.len;
            if (self.frag != null) out += 1;
            return out;
        }

        fn blockAt(self: Self, idx: usize) ![]u8 {
            if (idx >= self.sizes.len) return DataReaderError.InvalidIndex;
            const block = try self.alloc.alloc(u8, blk: {
                if (idx == self.numBlocks() - 1) break :blk self.file_size % self.block_size;
                break :blk self.block_size;
            });
            if (idx == self.sizes.len and self.frag != null) {
                @memcpy(block, self.frag.?);
                return;
            }
            if (self.sizes[idx].uncompressed) {
                _ = try self.rdr.pread(block, self.offsets[idx]);
                return;
            }
            _ = try self.comp.decompress(
                1024 * 1024,
                self.alloc,
                self.rdr.readerAt(self.offsets[idx]),
                block,
            );
            return block;
        }
    };
}

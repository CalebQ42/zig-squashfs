const std = @import("std");

const PRead = @import("p_read.zig").PRead;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

pub fn DataReader(comptime T: type) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        pool: ?*std.Thread.Pool = null,

        rdr: PRead(T),
        comp: Compression,
        offsets: []u64,

        file_size: u64,
        block_size: u32,
        sizes: []BlockSize,

        frag: []u8 = &[0]u8{},

        read_block: []u8,
        read_offset: u64,
        read_idx: u32 = 0,

        pub fn init(
            alloc: std.mem.Allocator,
            rdr: PRead(T),
            comp: Compression,
            init_offset: u64,
            file_size: u64,
            sizes: []BlockSize,
            block_size: u32,
        ) !Self {
            var cur_offset = init_offset;
            const offsets = alloc.alloc(u64, sizes.len);
            for (0..sizes.len) |i| {
                offsets[i] = cur_offset;
                cur_offset += sizes[i].size;
            }
            return .{
                .alloc = alloc,
                .rdr = rdr,
                .comp = comp,
                .offsets = offsets,
                .file_size = file_size,
                .block_size = block_size,
                .sizes = sizes,
            };
        }
        pub fn deinit(self: Self) void {
            self.alloc.free(self.offsets);
            self.alloc.free(self.frag);
        }

        pub fn addFragment(self: *Self, entry: FragEntry, offset: u32) !void {
            self.frag = try self.alloc.alloc(u8, self.file_size % self.block_size);
            if (entry.size.size == 0) {
                @memset(self.frag, 0);
                return;
            } else if (entry.size.uncompressed) {
                _ = try self.rdr.pread(self.frag, entry.block + offset);
                return;
            }
            const block = try self.alloc.alloc(u8, offset + self.frag.len);
            defer self.alloc.free(block);
            _ = try self.comp.decompress(
                self.alloc,
                std.io.limitedReader(
                    self.rdr.readerAt(entry.block),
                    entry.size.size,
                ),
                block,
            );
            @memcpy(self.frag, block[offset..]);
        }
        pub fn setPool(self: *Self, pool: *std.Thread.Pool) void {
            self.pool = pool;
        }

        fn blockAt(self: Self, idx: u32) ![]u8 {
            const size = if (idx == self.sizes.len - 1 and self.frag.len == 0) {
                self.file_size % self.block_size;
            } else {
                self.block_size;
            };
            const block = try self.alloc.alloc(u8, size);
            errdefer self.alloc.free(block);
            if (self.sizes[idx].size == 0) {
                @memset(block, 0);
                return block;
            } else if (self.sizes[idx].uncompressed) {
                _ = try self.rdr.pread(block, self.offsets[idx]);
                return block;
            }
            _ = try self.comp.decompress(
                self.alloc,
                std.io.limitedReader(
                    self.rdr.readerAt(self.offsets[idx]),
                    self.sizes[idx].size,
                ),
                block,
            );
            return block;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            var cur_red: usize = 0;
            while (cur_red < buf.len) {
                if (self.read_offset >= self.read_block.len) {
                    //TODO:
                }
                //TODO:
            }
            return cur_red;
        }

        /// Write the entire file's contents to the writer.
        /// If availble, pwrite will be used.
        /// If a thread pool is not set via setPool, one is created based on cpu thread count.
        pub fn writeTo(self: Self, writer: anytype) !usize {}
    };
}

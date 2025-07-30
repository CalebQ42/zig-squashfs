const std = @import("std");

const Inode = @import("../inode.zig");
const PRead = @import("p_read.zig").PRead;
const SfsReader = @import("../reader.zig").SfsReader;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

const CompletionMap = std.ArrayHashMap(usize, []u8);

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
            var wg: std.Thread.WaitGroup = .{};
            wg.startMany(self.numBlocks());
            var map: CompletionMap = .init(self.alloc);
            defer map.deinit();
            var mut: std.Thread.Mutex = .{};
            var cond: std.Thread.Condition = .{};
            std.Thread.spawn(.{ .allocator = self.alloc }, writeThread, .{ self, wrt, &map, &mut, &cond, null, null });
            for (0..self.numBlocks()) |i| {}
            wg.wait();
        }
        pub fn writeToNoBlock(self: Self, wrt: anytype, comptime finish: anytype, finish_args: anytype) !void {
            comptime std.debug.assert(std.meta.hasFn(@TypeOf(wrt), "write") or std.meta.hasFn(@TypeOf(wrt), "pwrite"));
            _ = self;
            _ = finish;
            _ = finish_args;
            return error{TODO}.TODO;
        }

        fn numBlocks(self: Self) usize {
            var out = self.sizes.len;
            if (self.frag != null) out += 1;
            return out;
        }
        /// Returns the decompressed data block at the given idx.
        /// If the block is sparse (filled with 0s), a zero length slice is returned.
        fn blockAt(self: Self, idx: usize) ![]u8 {
            if (idx >= self.numBlocks()) return DataReaderError.InvalidIndex;
            const size = self.sizes[idx];
            if (size.size == 0) return &[0]u8{};
            const block = try self.alloc.alloc(u8, blk: {
                if (idx == self.numBlocks() - 1) break :blk self.file_size % self.block_size;
                break :blk self.block_size;
            });
            if (idx == self.sizes.len and self.frag != null) {
                @memcpy(block, self.frag.?);
                return;
            }
            if (size.uncompressed) {
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

        fn writeThread(
            self: Self,
            wrt: anytype,
            map: *CompletionMap,
            mut: *std.Thread.Mutex,
            cond: *std.Thread.Condition,
            comptime finish: anytype,
            finish_args: anytype,
        ) void {
            var cur_idx: usize = 0;
            mut.lock();
            defer mut.unlock();
            while (cur_idx < self.numBlocks()) {
                cond.wait(mut);
                if (comptime std.meta.hasFn(@TypeOf(wrt), "pwrite")) {
                    for (map.keys()) |k| {
                        const blk = map.fetchSwapRemove(k).?.value;
                        defer self.alloc.free(blk);
                        if (blk.len > 0) {
                            _ = wrt.pwrite(map.fetchSwapRemove(k).?.value, self.block_size * k) catch |err| {
                                std.debug.print("ERROR: {}\n", .{err});
                                //TODO: handle properly.
                            };
                        } else {
                            _ = wrt.pwrite(&[1]u8{0}, (self.block_size * (k + 1)) - 1) catch |err| {
                                std.debug.print("ERROR: {}\n", .{err});
                                //TODO: handle properly.
                            };
                        }
                        cur_idx += 1;
                    }
                    continue;
                }
                while (map.contains(cur_idx)) {
                    const blk = map.fetchSwapRemove(cur_idx).?.value;
                    defer self.alloc.free(blk);
                    if (blk.len > 0) {
                        _ = wrt.write(blk) catch |err| {
                            std.debug.print("ERROR: {}\n", .{err});
                            //TODO: handle properly.
                        };
                    }
                    cur_idx += 1;
                }
            }
            if (comptime @TypeOf(finish) != @TypeOf(null) and @TypeOf(finish_args) != @TypeOf(null)) @call(.auto, finish, finish_args);
        }
        fn decompThread(
            self: Self,
            idx: usize,
            map: *CompletionMap,
            mut: *std.Thread.Mutex,
            cond: *std.Thread.Condition,
        ) void {}
    };
}

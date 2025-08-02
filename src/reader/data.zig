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
    ExtractionActive,
};

const DecompCompletion = struct {
    errs: std.ArrayList(anyerror),
    map: std.ArrayHashMap(usize, []u8),
    mut: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    fn init(alloc: std.mem.Allocator) DecompCompletion {
        return .{
            .errs = .init(alloc),
            .map = .init(alloc),
        };
    }
    fn deinit(self: *DecompCompletion) !void {
        self.active = false;
        self.errs.deinit();
        self.map.deinit();
    }

    fn clear(self: *DecompCompletion) void {
        self.errs.clearAndFree();
        self.map.clearAndFree();
    }

    fn add(self: *DecompCompletion, idx: usize, data: []u8) !void {
        self.mut.lock();
        defer self.mut.unlock();
        try self.map.put(idx, data);
    }
    fn addErr(self: *DecompCompletion, err: anyerror) void {
        self.errs.append(err) catch {};
    }

    fn getBlock(self: *DecompCompletion, idx: usize) ?[]u8 {
        const res = self.map.fetchSwapRemove(idx);
        if(res == null) return null;
        return res.?.value;
    }
    fn hasErrs(self: DecompCompletion) bool{
        return self.errs.items.len > 0;
    }
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

        completion: DecompCompletion,

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
                .completion = .init(rdr.alloc),
            };
        }
        pub fn deinit(self: *Self) void {
            self.alloc.free(self.offsets);
            self.completion.deinit();
        }

        pub fn addFragment(self: *Self, data: []u8) void {
            self.frag = data;
        }

        pub fn writeTo(self: *Self, wrt: anytype) !void {
            comptime std.debug.assert(std.meta.hasFn(@TypeOf(wrt), "write") or std.meta.hasFn(@TypeOf(wrt), "pwrite"));
            var write_thr = try std.Thread.spawn(
                .{ .allocator = self.alloc },
                writeThread,
                .{ self, wrt, null, null },
            );
            defer self.completion.clear();
            for (0..self.numBlocks()) |i| {
                var thr = std.Thread.spawn(
                    .{ .allocator = self.alloc },
                    decompThread,
                    .{ self, i },
                ) catch |err| {
                    self.completion.addErr(err);
                };
                thr.detach();
            }
            write_thr.join();
            if () return errs.items[0];
        }

        pub fn writeToNoBlock(self: Self, wrt: anytype, comptime finish: anytype, finish_args: anytype) !void {
            comptime std.debug.assert(std.meta.hasFn(@TypeOf(wrt), "write") or std.meta.hasFn(@TypeOf(wrt), "pwrite"));
            var map: DecompCompletion = .init(self.alloc);
            errdefer map.deinit();
            var mut = try self.alloc.create(std.Thread.Mutex);
            errdefer self.alloc.destroy(mut);
            mut.* = .{};
            var cond = try self.alloc.create(std.Thread.Condition);
            errdefer self.alloc.destroy(cond);
            cond.* = .{};
            var errs: std.ArrayList(anyerror) = .init(self.alloc);
            errdefer errs.deinit();
            var write_thr = try std.Thread.spawn(
                .{ .allocator = self.alloc },
                writeThread,
                .{ self, wrt, &errs, &map, &mut, &cond, finish, finish_args },
            );
            write_thr.detach();
            for (0..self.numBlocks()) |i| {
                var thr = std.Thread.spawn(
                    .{ .allocator = self.alloc },
                    decompThread,
                    .{ self, i, &errs, &map, &mut, &cond },
                ) catch |err| {
                    errs.append(err) catch {};
                };
                thr.detach();
            }
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
            errs: *std.ArrayList(anyerror),
            map: *DecompCompletion,
            mut: *std.Thread.Mutex,
            cond: *std.Thread.Condition,
            comptime finish: anytype,
            finish_args: anytype,
        ) void {
            var cur_idx: usize = 0;
            mut.lock();
            defer mut.unlock();
            while (cur_idx < self.numBlocks() and errs.items.len == 0) {
                cond.wait(mut);
                if (errs.items.len > 0) break;
                if (comptime std.meta.hasFn(@TypeOf(wrt), "pwrite")) {
                    for (map.keys()) |k| {
                        const blk = map.fetchSwapRemove(k).?.value;
                        defer self.alloc.free(blk);
                        if (blk.len > 0) {
                            _ = wrt.pwrite(map.fetchSwapRemove(k).?.value, self.block_size * k) catch |err| {
                                errs.append(err) catch {};
                                break;
                            };
                        } else {
                            _ = wrt.pwrite(&[1]u8{0}, (self.block_size * (k + 1)) - 1) catch |err| {
                                errs.append(err) catch {};
                                break;
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
                            errs.append(err) catch {};
                            break;
                        };
                    } else {
                        const blank: [1024 * 1024]u8 = [1]u8{0} ** (1024 * 1024);
                        _ = wrt.write(blank[0..self.block_size]) catch |err| {
                            errs.append(err) catch {};
                            break;
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
            errs: *std.ArrayList(anyerror),
            map: *DecompCompletion,
            mut: *std.Thread.Mutex,
            cond: *std.Thread.Condition,
        ) void {
            if (errs.items.len > 0) return;
            const block = self.blockAt(idx) catch |err| {
                errs.append(err) catch {};
                return;
            };
            mut.lock();
            defer mut.unlock();
            map.put(idx, block) catch |err| {
                errs.append(err) catch {};
            };
            cond.signal();
        }
    };
}

const std = @import("std");

const PRead = @import("p_read.zig").PRead;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

const DataReaderError = error{
    EOF,
    ThreadPoolNotSet,
};

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

        read_block: []u8 = &[0]u8{},
        read_offset: u64 = 0,
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
            const offsets = try alloc.alloc(u64, sizes.len);
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
                self.rdr.readerAt(entry.block).reader(),
                block,
            );
            @memcpy(self.frag, block[offset..]);
        }

        pub fn setPool(self: *Self, pool: *std.Thread.Pool) void {
            self.pool = pool;
        }

        fn blockAt(self: Self, idx: u32) ![]u8 {
            if (self.frag.len > 0 and idx == self.sizes.len) return self.frag;
            if (idx >= self.sizes.len) return DataReaderError.InvalidIndex;
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
                self.rdr.readerAt(self.offsets[idx]).reader(),
                block,
            );
            return block;
        }

        fn numBlocks(self: Self) usize {
            var out = self.sizes.len;
            if (self.frag.len > 0) out += 1;
            return out;
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            var cur_red: usize = 0;
            var to_read: usize = 0;
            while (cur_red < buf.len) {
                if (self.read_offset >= self.read_block.len) {
                    if (self.read_idx == self.sizes.len or (self.frag.len == 0 and self.read_idx == self.sizes.len - 1)) {
                        self.block_size = self.file_size % self.block_size;
                    }
                    self.read_block = self.blockAt(self.read_idx) catch |err| {
                        if (err == DataReaderError.EOF) return cur_red;
                        return err;
                    };
                    self.read_idx += 1;
                }
                to_read = @min(buf.len - cur_red, self.block_size - self.read_offset);
                @memcpy(buf[cur_red .. cur_red + to_read], self.read_block[self.read_offset .. self.read_offset + to_read]);
                cur_red += to_read;
                self.read_offset += to_read;
            }
            return cur_red;
        }

        /// Write the entire file's contents to the writer.
        /// If availble, pwrite will be used.
        pub fn writeTo(self: Self, writer: anytype) !usize {
            if (comptime self.pool == null) return DataReaderError.ThreadPoolNotSet;
            const mut: std.Thread.Mutex = .{};
            var cur_idx: usize = 0;
            const wg: std.Thread.WaitGroup = .{};
            const completed = comptime if (std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                std.ArrayList(anyerror).init(self.alloc);
            } else {
                std.AutoArrayHashMap(usize, anyerror![]u8).init(self.alloc);
            };
            defer completed.deinit();
            for (0..self.numBlocks()) |i| {
                wg.start();
                self.pool.?.spawn(
                    comptime if (std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                        extractThreadedPWrite;
                    } else {
                        extractThreaded;
                    },
                    comptime if (std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                        .{ self, &wg, &completed, i, writer };
                    } else {
                        .{ self, &mut, &cur_idx, &wg, &completed, i, writer };
                    },
                );
            }
            wg.wait();
            if (completed.items.len > 0) {
                return completed.items.get(0);
            }
            return self.file_size;
        }
        fn extractThreaded(
            self: Self,
            mut: *std.Thread.Mutex,
            cur_idx: *usize,
            wg: *std.Thread.WaitGroup,
            completed: *std.AutoArrayHashMap(usize, anyerror![]u8),
            idx: usize,
            writer: anytype,
        ) void {
            if (cur_idx.* >= self.sizes.len + 1) return;
            defer wg.finish();
            const block = self.blockAt(idx) catch |err| {
                cur_idx.* = self.sizes.len + 1;
                completed.put(idx, err) catch {};
                return;
            };
            defer if (idx < self.sizes.len) {
                self.alloc.free(block);
            };
            mut.lock();
            defer mut.unlock();
            if (cur_idx.* == idx) {
                _ = writer.write(block) catch |err| {
                    cur_idx.* = self.sizes.len + 1;
                    completed.put(idx, err) catch {};
                    return;
                };
            } else {
                completed.put(idx, block) catch |err| {
                    cur_idx.* = self.sizes.len + 1;
                    completed.put(idx, err) catch {};
                    return;
                };
            }
            if (completed.count() == 0) return;
            for (cur_idx.*..self.numBlocks()) |i| {
                const val = completed.get(i);
                if (val == null) return;
                _ = writer.write(block) catch |err| {
                    cur_idx.* = self.sizes.len + 1;
                    completed.put(i, err) catch {};
                    return;
                };
                cur_idx.* += 1;
                if (completed.count() == 0) return;
            }
        }
        fn extractThreadedPWrite(
            self: Self,
            wg: *std.Thread.WaitGroup,
            completed: *std.ArrayList(anyerror),
            idx: usize,
            writer: anytype,
        ) void {
            if (completed.items.len > 0) return;
            defer wg.finish();
            const block = self.blockAt(idx) catch |err| {
                completed.append(err) catch {};
                return;
            };
            defer if (idx < self.sizes.len) {
                self.alloc.free(block);
            };
            _ = writer.pwrite(idx * self.block_size, block) catch |err| {
                completed.append(err) catch {};
                return;
            };
        }
    };
}

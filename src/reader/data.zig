const std = @import("std");

const PRead = @import("p_read.zig").PRead;
const FragEntry = @import("../fragment.zig").FragEntry;
const BlockSize = @import("../inode/file.zig").BlockSize;
const Compression = @import("../superblock.zig").Compression;

const DataReaderError = error{
    EOF,
    ThreadPoolNotSet,
    InvalidIndex,
};

const DataBlock = struct {
    data: [1024 * 1024]u8, // Blocks can be up to 1MB in size.
    len: usize,
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

        frag: DataBlock = DataBlock{ .data = &[0]u8, .len = 0 },

        read_block: DataBlock = DataBlock{ .data = &[0]u8, .len = 0 },
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
            if (self.read_idx < self.sizes.len) self.alloc.free(self.read_block);
        }

        pub fn addFragment(self: *Self, entry: FragEntry, offset: u32) !void {
            self.frag.len = self.file_size % self.block_size;
            errdefer self.frag.len = 0;
            if (entry.size.size == 0) {
                @memset(self.frag.data, 0);
                return;
            } else if (entry.size.uncompressed) {
                _ = try self.rdr.pread(self.frag.data, entry.block + offset);
                return;
            }
            const block: [1024 * 1024]u8 = undefined;
            _ = try self.comp.decompress(
                1024 * 1024,
                self.alloc,
                self.rdr.readerAt(entry.block).reader(),
                block,
            );
            @memcpy(self.frag.data, block[offset..]);
        }

        pub fn setPool(self: *Self, pool: *std.Thread.Pool) void {
            self.pool = pool;
        }

        fn blockAt(self: Self, idx: usize) !DataBlock {
            if (self.frag.len > 0 and idx == self.sizes.len) return self.frag;
            if (idx >= self.sizes.len) return DataReaderError.InvalidIndex;
            const out: DataBlock = undefined;
            out.len = blk: {
                if (idx == self.sizes.len - 1 and self.frag.len == 0) {
                    break :blk self.file_size % self.block_size;
                }
                break :blk self.block_size;
            };
            if (self.sizes[idx].size == 0) {
                @memset(out.data[0..out.len], 0);
                return out;
            } else if (self.sizes[idx].uncompressed) {
                _ = try self.rdr.pread(out.data[0..out.len], self.offsets[idx]);
                return out;
            }
            _ = try self.comp.decompress(
                1024 * 1024,
                self.alloc,
                self.rdr.readerAt(self.offsets[idx]).reader(),
                out.data[0..out.len],
            );
            return out;
        }

        fn numBlocks(self: Self) usize {
            var out = self.sizes.len;
            if (self.frag.len > 0) out += 1;
            return out;
        }

        const Reader = std.io.GenericReader(*Self, anyerror, read);

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
                @memcpy(buf[cur_red .. cur_red + to_read], self.read_block.data[self.read_offset .. self.read_offset + to_read]);
                cur_red += to_read;
                self.read_offset += to_read;
            }
            return cur_red;
        }
        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        /// Write the entire file's contents to the writer using multiple threads.
        /// If availble, pwrite will be used.
        pub fn writeTo(self: Self, writer: anytype) !usize {
            if (self.pool == null) return DataReaderError.ThreadPoolNotSet;
            var mut: std.Thread.Mutex = .{};
            var cur_idx: usize = 0;
            var wg: std.Thread.WaitGroup = .{};
            var completed: std.AutoHashMap(usize, DataBlock) = .init(self.alloc);
            defer completed.deinit();
            var errs: std.ArrayList(anyerror) = .init(self.alloc);
            defer errs.deinit();
            for (0..self.numBlocks()) |i| {
                wg.start();
                self.pool.?.spawn(
                    comptime blk: {
                        if (std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                            break :blk writeToThreadPWrite;
                        }
                        break :blk writeToThread;
                    },
                    blk: {
                        if (comptime std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                            break :blk .{ self, &wg, &errs, i, writer };
                        }
                        break :blk .{ self, &wg, &mut, &cur_idx, &errs, &completed, i, writer };
                    },
                );
            }
            wg.wait();
            if (errs.items.len > 0) return errs.items[0];
            return self.file_size;
        }
        /// Similiar to writeTo, but does not block until finished.
        /// Calls on_finish when all blocks have been written.
        pub fn writeToNoBlock(
            self: Self,
            errs: *std.ArrayList(anyerror),
            writer: anytype,
            comptime on_finish: anytype,
            on_finish_args: anytype,
        ) !void {
            if (self.pool == null) return DataReaderError.ThreadPoolNotSet;
            if (self.numBlocks() == 0) {
                @call(.auto, on_finish, on_finish_args);
                return;
            }
            var mut: std.Thread.Mutex = .{};
            var cur_idx: usize = 0;
            var block_wg = try self.alloc.create(std.Thread.WaitGroup);
            block_wg.* = .{};
            const finish_mut = try self.alloc.create(std.Thread.Mutex);
            finish_mut.* = .{};
            var completed: ?std.AutoHashMap(usize, DataBlock) = null;
            if (!comptime std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                completed = std.AutoHashMap(usize, DataBlock).init(self.alloc);
            }
            block_wg.startMany(self.numBlocks());
            for (0..self.numBlocks()) |i| {
                var thr = try std.Thread.spawn(
                    .{ .allocator = self.alloc },
                    comptime blk: {
                        if (std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                            break :blk noBlockThreadPWrite;
                        }
                        break :blk noBlockThread;
                    },
                    blk: {
                        if (comptime std.meta.hasFn(@TypeOf(writer), "pwrite")) {
                            break :blk .{ self, block_wg, errs, i, writer, finish_mut, on_finish, on_finish_args };
                        } else {
                            break :blk .{ self, block_wg, &mut, &cur_idx, errs, &completed.?, i, writer, finish_mut, on_finish, on_finish_args };
                        }
                    },
                );
                thr.detach();
            }
        }

        fn writeBlockTo(
            self: Self,
            mut: *std.Thread.Mutex,
            cur_idx: *usize,
            errs: *std.ArrayList(anyerror),
            completed: *std.AutoHashMap(usize, DataBlock),
            idx: usize,
            writer: anytype,
        ) void {
            //TODO: We can marginally reduce memory usage if we don't store sparse blocks in completed.
            if (errs.items.len > 0) return; // Indicates an error has occured in another thread.
            const block = self.blockAt(idx) catch |err| {
                errs.append(err) catch {};
                return;
            };
            defer if (idx < self.sizes.len) {
                self.alloc.free(block);
            };
            mut.lock();
            defer mut.unlock();
            if (cur_idx.* == idx) {
                _ = writer.write(block) catch |err| {
                    errs.append(err) catch {};
                    return;
                };
            } else {
                completed.put(idx, block) catch |err| {
                    errs.append(err) catch {};
                    return;
                };
            }
            if (completed.count() == 0) return;
            for (cur_idx.*..self.numBlocks()) |i| {
                const val = completed.get(i);
                if (val == null) return;
                _ = writer.write(val.?) catch |err| {
                    errs.append(err) catch {};
                    return;
                };
                _ = completed.remove(i);
                cur_idx.* += 1;
                if (completed.count() == 0) return;
            }
        }
        fn writeBlockToPWrite(
            self: Self,
            errs: *std.ArrayList(anyerror),
            idx: usize,
            writer: anytype,
        ) void {
            if (errs.items.len > 0) return;
            if (idx < self.sizes.len and self.sizes[idx].size == 0) {
                var pos = idx * self.block_size;
                if (self.frag.len == 0 and idx == self.sizes.len - 1) {
                    pos += self.file_size % self.block_size;
                } else {
                    pos += self.block_size;
                }
                _ = writer.pwrite(&[1]u8{0}, pos - 1) catch |err| {
                    errs.append(err) catch {};
                };
            } else {
                const block = self.blockAt(idx) catch |err| {
                    errs.append(err) catch {};
                    return;
                };
                defer if (idx < self.sizes.len) {
                    self.alloc.free(block);
                };
                _ = writer.pwrite(block, idx * self.block_size) catch |err| {
                    errs.append(err) catch {};
                    return;
                };
            }
        }

        fn writeToThread(
            self: Self,
            wg: *std.Thread.WaitGroup,
            mut: *std.Thread.Mutex,
            cur_idx: *usize,
            errs: *std.ArrayList(anyerror),
            completed: *std.AutoHashMap(usize, DataBlock),
            idx: usize,
            writer: anytype,
        ) void {
            self.writeBlockTo(mut, cur_idx, errs, completed, idx, writer);
            wg.finish();
        }
        fn writeToThreadPWrite(
            self: Self,
            wg: *std.Thread.WaitGroup,
            errs: std.ArrayList(anyerror),
            idx: usize,
            writer: anytype,
        ) void {
            self.writeBlockToPWrite(errs, idx, writer);
            wg.finish();
        }

        fn noBlockThread(
            self: Self,
            block_wg: *std.Thread.WaitGroup,
            mut: *std.Thread.Mutex,
            cur_idx: *usize,
            errs: *std.ArrayList(anyerror),
            completed: *std.AutoHashMap(usize, DataBlock),
            idx: usize,
            writer: anytype,
            finish_mut: *std.Thread.Mutex,
            comptime on_finish: anytype,
            on_finish_args: anytype,
        ) void {
            self.writeBlockTo(mut, cur_idx, errs, completed, idx, writer);
            finish_mut.lock();
            block_wg.finish();
            defer finish_mut.unlock();
            if (block_wg.isDone()) {
                @call(.auto, on_finish, on_finish_args);
                completed.deinit();
            }
        }
        fn noBlockThreadPWrite(
            self: Self,
            block_wg: *std.Thread.WaitGroup,
            errs: *std.ArrayList(anyerror),
            idx: usize,
            writer: anytype,
            finish_mut: *std.Thread.Mutex,
            comptime on_finish: anytype,
            on_finish_args: anytype,
        ) void {
            self.writeBlockToPWrite(errs, idx, writer);
            finish_mut.lock();
            block_wg.finish();
            const isDone = block_wg.isDone();
            defer {
                finish_mut.unlock();
                if (isDone) self.alloc.destroy(finish_mut);
            }
            if (isDone) {
                self.alloc.destroy(block_wg);
                @call(.auto, on_finish, on_finish_args);
            }
        }
    };
}

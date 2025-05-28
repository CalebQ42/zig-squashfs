const std = @import("std");
const fs = std.fs;
const io = std.io;

const File = @import("../file.zig").File;
const Reader = @import("../reader.zig").Reader;
const BlockSize = @import("../inode/file.zig").BlockSize;
const DecompressionType = @import("../decompress.zig").DecompressType;
const FileHolder = @import("../readers/file_holder.zig").FileHolder;
const FileOffsetWriter = @import("../readers/file_holder.zig").FileOffsetWriter;
const DataReader = @import("data_reader.zig").DataReader;
const Config = @import("../file.zig").Config;

/// A specialized File data reader that's meant to write all of it's data at once.
/// Can be re-used freely until deinit() is called.
pub const DataExtractor = struct {
    alloc: std.mem.Allocator,
    decomp: DecompressionType,
    holder: *FileHolder,
    block_size: u32,
    file_size: u64,
    sizes: []BlockSize,
    block_offset: []u64,
    frag_data: ?[]u8 = null,

    pub fn init(fil: *File, reader: *Reader) !DataExtractor {
        var data_start: u64 = 0;
        var sizes: []BlockSize = undefined;
        var file_size: u64 = 0;
        var frag_idx: u32 = 0;
        var frag_offset: u32 = 0;
        switch (fil.inode.data) {
            .file => |f| {
                data_start = f.data_start;
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                file_size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            .ext_file => |f| {
                data_start = f.data_start;
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                file_size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            else => return File.FileError.NotNormalFile,
        }
        var out: DataExtractor = .{
            .alloc = reader.alloc,
            .decomp = reader.super.decomp,
            .holder = &reader.holder,
            .block_size = reader.super.block_size,
            .file_size = file_size,
            .sizes = sizes,
            .block_offset = try reader.alloc.alloc(u64, sizes.len),
        };
        errdefer out.deinit();
        var offset: u64 = data_start;
        for (0.., out.block_offset) |i, _| {
            out.block_offset[i] = offset;
            offset += out.sizes[i].size;
        }
        if (frag_idx != 0xFFFFFFFF) {
            const frag_ent = try reader.frag_table.getValue(reader, frag_idx);
            out.frag_data = try frag_ent.getData(reader, frag_offset, @truncate(file_size % reader.super.block_size));
        }
        return out;
    }

    pub fn deinit(self: *DataExtractor) void {
        self.alloc.free(self.sizes);
        self.alloc.free(self.block_offset);
        if (self.frag_data != null) self.alloc.free(self.frag_data.?);
    }

    fn processBlockToFile(self: *DataExtractor, wg: *std.Thread.WaitGroup, errs: *MutexList, block_ind: usize, fil: *fs.File) void {
        defer wg.finish();
        if (self.sizes[block_ind].not_compressed) {
            @branchHint(.unlikely);
            if (self.sizes[block_ind].size == 0) {
                if (block_ind == self.sizes.len - 1) {
                    fil.pwriteAll(&[1]u8{0}, self.file_size - 1) catch |err| {
                        std.debug.print("yo1\n", .{});
                        errs.append(err) catch {};
                    };
                } else {
                    fil.pwriteAll(&[1]u8{0}, ((block_ind + 1) * self.block_size) - 1) catch |err| {
                        std.debug.print("yo2\n", .{});
                        errs.append(err) catch {};
                    };
                }
                return;
            }
            const dat = self.alloc.alloc(u8, self.sizes[block_ind].size) catch |err| {
                errs.append(err) catch {};
                return;
            };
            defer self.alloc.free(dat);
            _ = self.holder.file.preadAll(dat, self.block_offset[block_ind]) catch |err| {
                errs.append(err) catch {};
                return;
            };
            fil.pwriteAll(dat, block_ind * self.block_size) catch |err| {
                errs.append(err) catch {};
            };
        } else {
            @branchHint(.likely);
            const offset_rdr = self.holder.readerAt(self.block_offset[block_ind]);
            var fil_wrtr: FileOffsetWriter = .init(fil, block_ind * self.block_size);
            var limit = std.io.limitedReader(offset_rdr, self.sizes[block_ind].size);
            self.decomp.decompressTo(
                self.alloc,
                limit.reader().any(),
                fil_wrtr.any(),
            ) catch |err| {
                errs.append(err) catch {};
            };
        }
    }

    fn fragmentToFile(self: *DataExtractor, wg: *std.Thread.WaitGroup, errs: *MutexList, fil: *fs.File) void {
        defer wg.finish();
        fil.pwriteAll(self.frag_data.?, self.block_size * self.sizes.len) catch |err| {
            errs.append(err) catch {};
        };
    }

    /// Write the data completely to the given file.
    /// Ignores the file's current offset and writes from the beginning of the file.
    /// Returns the amount of bytes written.
    ///
    /// Optimized for lower memory usage by using File.pwrite.
    pub fn writeToFile(self: *DataExtractor, pool: *std.Thread.Pool, fil: *fs.File) !void {
        var wg: std.Thread.WaitGroup = .{};
        var errs: MutexList = .init(self.alloc);
        defer errs.deinit();
        for (0..self.sizes.len) |i| {
            wg.start();
            try pool.spawn(processBlockToFile, .{ self, &wg, &errs, i, fil });
        }
        if (self.frag_data != null) {
            wg.start();
            try pool.spawn(fragmentToFile, .{ self, &wg, &errs, fil });
        }
        wg.wait();
        if (errs.list.items.len > 0) {
            //TODO: better handle all the errors
            return errs.list.items[0];
        }
    }

    // fn processBlock(self: *DataExtractor, errs: std.ArrayList(anyerror), data_out: std.AutoHashMap([]u8), block_ind: u32) void {
    //     const offset_rdr = self.holder.readerAt(self.block_offset[block_ind]);
    //     const out = self.decomp.decompress(
    //         self.alloc,
    //         std.io.limitedReader(offset_rdr, self.sizes[block_ind].size),
    //     ) catch |err| {
    //         errs.append(err);
    //         return;
    //     };
    //     data_out.put(block_ind, )
    // }

    // Write the data completely to the given writer.
    // Returns the amount of bytes written.
    //
    // To write data in order, some data may end up cached temporarily.
    // pub fn writeToWriter(self: DataExtractor, pool: *std.Thread.Pool, writer: io.AnyWriter) !void {
    //     const wg: std.Thread.WaitGroup = .{};
    //     const errs: std.ArrayList(anyerror) = .init(self.alloc);
    //     const data: std.AutoHashMap(u32, []u8) = .init(self.alloc);
    //     const cond: std.Thread. = .{};
    //     defer errs.deinit();
    //     for (0..self.sizes.len) |i| {
    //         pool.spawnWg(&wg, processBlock, .{ &self, i, fil });
    //     }
    //     wg.wait();
    // }
};

const MutexList = struct {
    list: std.ArrayList(anyerror),
    mut: std.Thread.Mutex = .{},

    fn init(alloc: std.mem.Allocator) MutexList {
        return .{
            .list = .init(alloc),
        };
    }
    fn deinit(self: *MutexList) void {
        self.list.deinit();
    }

    fn append(self: *MutexList, err: anyerror) !void {
        self.mut.lock();
        defer self.mut.unlock();
        try self.list.append(err);
    }
};

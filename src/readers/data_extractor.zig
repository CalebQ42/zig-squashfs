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
    sizes: []BlockSize,
    block_offset: []u64,
    frag_data: ?[]u8 = null,

    pub fn init(fil: *File, reader: *Reader) !DataExtractor {
        var data_start: u64 = 0;
        var sizes: []BlockSize = undefined;
        var size: u64 = 0;
        var frag_idx: u32 = 0;
        var frag_offset: u32 = 0;
        switch (fil.inode.data) {
            .file => |f| {
                data_start = f.data_start;
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            .ext_file => |f| {
                data_start = f.data_start;
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                size = f.size;
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
            const frag_entry = try reader.frag_table.getValue(reader, frag_idx);
            var frag_rdr: DataReader = try .fromFragEntry(reader, frag_entry);
            std.debug.print("{} {}\n", .{ frag_offset, frag_entry });
            defer frag_rdr.deinit();
            try frag_rdr.skip(frag_offset);
            out.frag_data = try reader.alloc.alloc(u8, size % out.block_size);
            _ = try frag_rdr.any().readAll(out.frag_data.?);
        }
        return out;
    }

    pub fn deinit(self: *DataExtractor) void {
        self.alloc.free(self.sizes);
        self.alloc.free(self.block_offset);
        if (self.frag_data != null) self.alloc.free(self.frag_data.?);
    }

    fn processBlockToFile(self: *DataExtractor, wg: *std.Thread.WaitGroup, errs: *std.ArrayList(anyerror), block_ind: usize, fil: *fs.File) void {
        defer wg.finish();
        const offset_rdr = self.holder.readerAt(self.block_offset[block_ind]);
        var fil_wrtr: FileOffsetWriter = .init(fil, block_ind * self.block_size);
        var limit = std.io.limitedReader(offset_rdr, self.sizes[block_ind].size);
        self.decomp.decompressTo(
            self.alloc,
            limit.reader().any(),
            fil_wrtr.any(),
        ) catch |err| {
            errs.append(err) catch |ignored_err| {
                std.debug.print("{}\n", .{ignored_err});
            };
        };
    }

    fn fragmentToFile(self: *DataExtractor, wg: *std.Thread.WaitGroup, errs: *std.ArrayList(anyerror), fil: *fs.File) void {
        defer wg.finish();
        fil.pwriteAll(self.frag_data.?, self.block_size * self.sizes.len) catch |err| {
            errs.append(err) catch |ignored_err| {
                std.debug.print("{}\n", .{ignored_err});
            };
        };
    }

    /// Write the data completely to the given file.
    /// Ignores the file's current offset and writes from the beginning of the file.
    /// Returns the amount of bytes written.
    ///
    /// Optimized for lower memory usage by using File.pwrite.
    pub fn writeToFile(self: *DataExtractor, pool: *std.Thread.Pool, fil: *fs.File) !void {
        var wg: std.Thread.WaitGroup = .{};
        var errs: std.ArrayList(anyerror) = .init(self.alloc);
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
        //TODO: see if there's any errors
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

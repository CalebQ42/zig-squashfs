const std = @import("std");
const fs = std.fs;

const File = @import("../file.zig").File;
const Reader = @import("../reader.zig").Reader;
const BlockSize = @import("../inode/file.zig").BlockSize;
const DecompressionType = @import("../decompress.zig").DecompressType;
const FileHolder = @import("../readers/file_holder.zig").FileHolder;
const DataReader = @import("data_reader.zig").DataReader;

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
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                data_start = f.data_start;
                size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            .ext_file => |f| {
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                @memcpy(sizes, f.blocks);
                data_start = f.data_start;
                size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            else => return File.FileError.NotNormalFile,
        }
        var out: DataExtractor = .{
            .alloc = reader.alloc,
            .decomp = reader.super.decomp,
            .holder = reader.holder,
            .block_size = reader.super.block_size,
            .sizes = sizes,
            .block_offset = try reader.alloc.alloc(u64, sizes.len),
            .data_start = data_start,
        };
        errdefer out.deinit();
        var offset: u64 = data_start;
        for (0..out.block_offset) |i| {
            out.block_offset[i] = offset;
            offset += out.sizes[i].size;
        }
        if (frag_idx != 0xFFFFFFFF) {
            const frag_entry = try reader.frag_table.getValue(frag_idx);
            var frag_rdr: DataReader = try .fromFragEntry(reader, frag_entry);
            defer frag_rdr.deinit();
            try frag_rdr.skip(frag_offset);
            out.frag_data = try reader.alloc.alloc(u8, size % out.block_size);
            _ = try frag_rdr.any().readAll(out.frag_data);
        }
        return out;
    }

    pub fn deinit(self: *DataExtractor) void {
        self.alloc.free(self.sizes);
        self.alloc.free(self.block_offset);
        if (self.cur_bloc.len > 0) self.alloc.free(self.cur_bloc);
        if (self.frag_data != null) self.alloc.free(self.frag_data);
    }

    fn processBlock(self: DataExtractor, block_ind: u32) ![]u8 {
        //TODO
    }

    fn processBlockToFile(self: DataExtractor, block_ind: u32, fil: *fs.File) !void {
        //TODO
    }

    /// Write the data completely to the given file.
    /// Ignores the file's current offset and writes from the beginning of the file.
    /// Returns the amount of bytes written.
    ///
    /// Optimized for lower memory usage by using File.pwrite.
    pub fn writeToFile(self: DataExtractor, fil: *fs.File) !void {
        //TODO
    }

    /// Write the data completely to the given writer.
    /// Returns the amount of bytes written.
    ///
    /// To write data in order, some data may end up cached temporarily.
    pub fn writeToWriter(self: DataExtractor, writer: io.AnyWriter) !void {
        //TODO
    }
};

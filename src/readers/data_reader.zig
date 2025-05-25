const std = @import("std");
const io = std.io;
const fs = std.fs;

const File = @import("../file.zig").File;
const Reader = @import("../reader.zig").Reader;
const BlockSize = @import("../inode/file.zig").BlockSize;
const DecompressionType = @import("../decompress.zig").DecompressType;
const FileOffsetReader = @import("../readers/file_holder.zig").FileOffsetReader;

pub const FragEntry = packed struct { start: u64, size: BlockSize, _: u32 };

const DataReaderError = error{
    EOF,
};

pub const DataReader = struct {
    alloc: std.mem.Allocator,
    decomp: DecompressionType,
    rdr: FileOffsetReader,
    block_size: u32,
    sizes: []BlockSize,
    frag_data: ?[]u8 = null,

    next_block_num: u32 = 0,
    cur_bloc: []u8 = &[0]u8{},
    cur_offset: u32 = 0,

    pub fn init(fil: *File, reader: *Reader) !DataReader {
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
        var out: DataReader = .{
            .alloc = reader.alloc,
            .decomp = reader.super.decomp,
            .rdr = reader.holder.readerAt(data_start),
            .block_size = reader.super.block_size,
            .sizes = sizes,
        };
        errdefer out.deinit();
        if (frag_idx != 0xFFFFFFFF) {
            const frag_entry = try reader.frag_table.getValue(frag_idx);
            var frag_rdr = try .fromFragEntry(reader, frag_entry);
            defer frag_rdr.deinit();
            try frag_rdr.skip(frag_offset);
            out.frag_data = try reader.alloc.alloc(u8, size % out.block_size);
            _ = try frag_rdr.any().readAll(out.frag_data);
        }
        return out;
    }
    pub fn fromFragEntry(reader: *Reader, ent: FragEntry) !DataReader {
        const size = try reader.alloc.alloc(BlockSize, 1);
        size[0] = ent.size;
        return .{
            .alloc = reader.alloc,
            .decomp = reader.super.decomp,
            .rdr = reader.holder.readerAt(ent.start),
            .block_size = reader.super.block_size,
            .sizes = size,
        };
    }

    pub fn deinit(self: *DataReader) void {
        self.alloc.free(self.sizes);
        if (self.cur_bloc.len > 0) self.alloc.free(self.cur_bloc);
        if (self.frag_data != null) self.alloc.free(self.frag_data.?);
    }

    pub fn skip(self: *DataReader, offset: u32) !void {
        var cur_skip: u32 = 0;
        var to_skip: u32 = 0;
        while (cur_skip < offset) {
            if (self.cur_offset >= self.cur_bloc.len) try self.readNextBlock();
            to_skip = @min(offset - cur_skip, self.cur_bloc.len - self.cur_offset);
            cur_skip += to_skip;
            self.cur_offset += to_skip;
        }
    }

    fn readNextBlock(self: *DataReader) !void {
        if (self.next_block_num == self.sizes.len) {
            if (self.cur_bloc.len > 0) self.alloc.free(self.cur_bloc);
            return DataReaderError.EOF;
        }
        const siz = self.sizes[self.next_block_num];
        self.next_block_num += 1;
        if (self.next_block_num == self.sizes.len - 1 and self.frag_data != null) {
            try self.sizeBlock(self.frag_data.?.len);
            @memcpy(self.cur_bloc, self.frag_data.?);
            return;
        }
        if (siz.size == 0) {
            try self.sizeBlock(self.block_size);
            @memset(self.cur_bloc, 0);
            return;
        }
        if (siz.not_compressed) {
            try self.sizeBlock(siz.size);
            _ = try self.rdr.any().readAll(self.cur_bloc);
        } else {
            self.alloc.free(self.cur_bloc);
            var limit = std.io.limitedReader(self.rdr, siz.size);
            var dat = try self.decomp.decompress(self.alloc, limit.reader().any());
            self.cur_bloc = try dat.toOwnedSlice();
        }
    }

    fn sizeBlock(self: *DataReader, size: usize) !void {
        if (!self.alloc.resize(self.cur_bloc, size)) {
            self.alloc.free(self.cur_bloc);
            self.cur_bloc = try self.alloc.alloc(u8, size);
        }
    }

    pub fn read(self: *DataReader, bytes: []u8) !usize {
        var cur_read: usize = 0;
        var to_read: usize = 0;
        while (cur_read < bytes.len) {
            if (self.cur_offset >= self.cur_bloc.len) {
                self.readNextBlock() catch |err| {
                    if (err == DataReaderError.EOF) return cur_read;
                    return err;
                };
            }
            to_read = @min(bytes.len - cur_read, self.cur_bloc.len - self.cur_offset);
            @memcpy(bytes[cur_read..], self.cur_bloc[self.cur_offset .. @as(usize, self.cur_offset) + to_read]);
            self.cur_offset += @truncate(to_read);
            cur_read += to_read;
        }
        return cur_read;
    }

    pub fn any(self: *DataReader) io.AnyReader {
        return .{
            .context = @ptrCast(self),
            .readFn = readOpaque,
        };
    }

    fn readOpaque(context: *const anyopaque, bytes: []u8) !usize {
        var self: *DataReader = @constCast(@ptrCast(@alignCast(context)));
        return self.read(bytes);
    }
};

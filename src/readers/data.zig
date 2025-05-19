const std = @import("std");
const io = std.io;

const File = @import("../file.zig").File;
const Reader = @import("../reader.zig").Reader;
const BlockSize = @import("../inode/file.zig").BlockSize;
const DecompressionType = @import("../decompress.zig").DecompressType;

const DataReaderError = error{
    EOF,
};

pub const DataReader = struct {
    alloc: std.mem.Allocator,
    decomp: DecompressionType,
    rdr: io.AnyReader,
    block_size: u32,
    sizes: []BlockSize,
    frag_rdr: ?io.AnyReader,

    next_block_num: u32 = 0,
    cur_bloc: []u8 = undefined,
    cur_offset: u32 = 0,

    pub fn init(fil: *File, reader: *Reader) !DataReader {
        const data_start: u64 = 0;
        const sizes: []BlockSize = undefined;
        const size: u64 = 0;
        const frag_idx: u32 = 0;
        const frag_offset: u32 = 0;
        switch (fil.inode.data) {
            .file => |f| {
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                std.mem.copyForwards(BlockSize, sizes, f.blocks);
                data_start = f.data_start;
                size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            .ext_file => |f| {
                sizes = try reader.alloc.alloc(BlockSize, f.blocks.len);
                std.mem.copyForwards(BlockSize, sizes, f.blocks);
                data_start = f.data_start;
                size = f.size;
                frag_idx = f.frag_idx;
                frag_offset = f.frag_offset;
            },
            else => return File.FileError.NotNormalFile,
        }
        //TODO: set-up frag_rdr
    }

    pub fn deinit(self: *DataReader) void {
        if (self.cur_bloc.len > 0) self.alloc.free(self.cur_bloc);
    }

    pub fn skip(self: *DataReader, offset: u32) !void {
        var cur_skip: u32 = 0;
        var to_skip: u32 = 0;
        while (cur_skip < offset) {
            if (self.offset >= self.block.len) try self.readNextBlock();
            to_skip = @min(offset - cur_skip, self.block.len - self.offset);
            cur_skip += to_skip;
            self.offset += to_skip;
        }
    }

    fn readNextBlock(self: *DataReader) !void {
        if (self.next_block_num == self.sizes.len) {
            if (self.cur_bloc.len > 0) self.alloc.free(self.cur_bloc);
            return DataReaderError.EOF;
        }
        const siz = self.sizes[self.next_block_num];
        self.next_block_num += 1;
        if (self.next_block_num == self.sizes.len - 1 and self.frag_rdr != null) {
            _ = try self.frag_rdr.?.readAll(self.cur_bloc);
            return;
        }
        if (siz.size == 0) {}
        if (siz.not_compressed) {}
    }

    pub fn read(self: *DataReader, bytes: []u8) !usize {
        var cur_read: usize = 0;
        var to_read: usize = 0;
        while (cur_read < bytes.len) {
            if (self.offset >= self.block.len) {
                if (self.readNextBlock()) |err| {
                    if (err == DataReaderError.EOF) return cur_read;
                    return err;
                }
            }
            to_read = @min(bytes.len - cur_read, self.block.len - self.offset);
            std.mem.copyForwards(u8, bytes[cur_read..], self.block[self.offset .. @as(usize, self.offset) + to_read]);
            self.offset += @truncate(to_read);
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

pub const DataExtractor = struct {};

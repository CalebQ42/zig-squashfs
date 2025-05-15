const std = @import("std");

const CompressionType = @import("decompress.zig").CompressionType;

const DirHeader = packed struct {
    count: u32,
    inode_block_start: u32,
    inode_num: u32,
};

const RawDirEntry = struct {
    inode_offset: u16,
    inode_num_difference: i16,
    inode_type: u16,
    name_size: u16,
    name: []u8,

    fn init(rdr: std.io.AnyReader, alloc: std.mem.Allocator) !DirEntry {
        var out: DirEntry = .{
            .inode_offset = try rdr.readInt(u16, std.builtin.Endian.little),
            .inode_num_difference = try rdr.readInt(i16, std.builtin.Endian.little),
            .inode_type = try rdr.readInt(u16, std.builtin.Endian.little),
            .name_size = try rdr.readInt(u16, std.builtin.Endian.little),
            .name = undefined,
        };
        out.name = try alloc.alloc(u8, out.name_size);
        _ = try rdr.readAll(out.name);
        return out;
    }
};

pub const DirEntry = struct {
    inode_offset: u16,
    inode_block_start: u32,
    inode_num: u32,
    name: []u8,

    fn init(raw: RawDirEntry, hdr: DirHeader) DirEntry {
        return .{
            .inode_offset = raw.inode_offset,
            .inode_block_start = hdr.inode_block_start,
            .inode_num = hdr.inode_num - raw.inode_num_difference,
            .name = raw.name,
        };
    }
};

const MetadataHeader = @import("metadata_reader.zig").MetadataHeader;

pub fn readDirEntries(alloc: std.mem.Allocator, comp: CompressionType, rdr: std.io.AnyReader, size: u32) ![]DirEntry {
    var total_size: u32 = 3;
    var meta_hdr: MetadataHeader = undefined;
    var dir_hdr: DirHeader = undefined;
    var buf: []u8 = undefined;
    var buf_rdr: std.io.FixedBufferStream(u8) = undefined;
    var i = 0;
    var entries: std.ArrayList(DirEntry) = .init(alloc);
    defer alloc.free(buf);
    while (total_size < size) {
        meta_hdr = try rdr.readStruct(MetadataHeader);
        if (meta_hdr.not_compressed) {
            buf = try alloc.realloc(buf, meta_hdr.size);
            _ = try rdr.readAll(rdr);
        } else {
            alloc.free(buf);
            buf = try comp.Decompress(alloc, std.io.limitedReader(rdr, meta_hdr.size));
        }
        buf_rdr = std.io.fixedBufferStream(buf);
        dir_hdr = try buf_rdr.reader().readStruct(DirHeader);
        total_size += 12;
        i = 0;
        while (i < dir_hdr.count) : (i += 1) {
            entries.append(try .init(try .init(buf_rdr, alloc), dir_hdr));
        }
    }
    return try entries.toOwnedSlice();
}

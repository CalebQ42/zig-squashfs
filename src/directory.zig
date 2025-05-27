const std = @import("std");
const io = std.io;

const InodeType = @import("inode/inode.zig").InodeType;

const DirHeader = extern struct {
    count: u32,
    inode_block_start: u32,
    inode_num: u32,
};

const RawDirEntryStart = packed struct {
    inode_block_offset: u16,
    /// Difference from the current DirHeader inode_num
    inode_num_difference: i16,
    /// Extended inodes will be their basic type.
    inode_type: InodeType,
    name_size: u16,
};

pub const DirEntry = struct {
    block_start: u32,
    offset: u16,
    inode_num: u32,
    name: []const u8,

    fn init(alloc: std.mem.Allocator, hdr: DirHeader, rdr: io.AnyReader) !DirEntry {
        const raw = try rdr.readStruct(RawDirEntryStart);
        const name = try alloc.alloc(u8, raw.name_size + 1);
        errdefer alloc.free(name);
        _ = try rdr.read(name);
        return .{
            .block_start = hdr.inode_block_start,
            .offset = raw.inode_block_offset,
            .inode_num = if (raw.inode_num_difference > 0)
                hdr.inode_num + @abs(raw.inode_num_difference)
            else
                hdr.inode_num - @abs(raw.inode_num_difference),
            .name = name,
        };
    }

    pub fn deinit(self: DirEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn readDirectory(alloc: std.mem.Allocator, rdr: io.AnyReader, size: u64) !std.StringHashMap(DirEntry) {
    var out: std.StringHashMap(DirEntry) = .init(alloc);
    errdefer out.deinit();
    var red_size: u64 = 3;
    var hdr: DirHeader = undefined;
    while (red_size < size) {
        hdr = try rdr.readStruct(DirHeader);
        red_size += 12;
        var i: u32 = 0;
        try out.ensureUnusedCapacity(hdr.count + 1);
        while (i <= hdr.count) : (i += 1) {
            var tmp: DirEntry = try .init(alloc, hdr, rdr);
            errdefer tmp.deinit(alloc);
            out.putAssumeCapacity(tmp.name, tmp);
            red_size += 8 + tmp.name.len;
        }
    }
    return out;
}

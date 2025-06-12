const std = @import("std");

const InodeType = @import("inode.zig").Type;

const Header = struct {
    count: u32,
    block: u32,
    num: u32,
};

const RawEntry = struct {
    offset: u16,
    num_offset: i16,
    inode_type: InodeType,
    name_size: u16,
};

pub const Entry = struct {
    block: u32,
    inode_num: u32,
    offset: u16,
    inode_type: InodeType,
    name: []const u8,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn readEntries(alloc: std.mem.Allocator, rdr: anytype, size: u64) ![]Entry {
    comptime std.debug.assert(std.meta.hasFn(rdr, "readAll"));
    const cur_red = 3;
    var hdr: Header = undefined;
    var i: u32 = 0;
    var raw: RawEntry = undefined;
    var out: std.ArrayList(Entry) = .init(alloc);
    errdefer out.deinit();
    while (cur_red < size) {
        _ = try rdr.readAll(std.mem.asBytes(&hdr));
        cur_red += @sizeOf(Header);
        try out.ensureUnusedCapacity(hdr.count + 1);
        i = 0;
        while (i < hdr.count + 1) : (i += 1) {
            _ = try rdr.readAll(std.mem.asBytes(&raw));
            cur_red += @sizeOf(RawEntry + raw.name_size + 1);
            const name = try alloc.alloc(u8, raw.name_size + 1);
            errdefer alloc.free(name);
            out.appendAssumeCapacity(.{
                .block = hdr.block,
                .inode_num = hdr.num + raw.num_offset,
                .offset = raw.offset,
                .inode_type = raw.inode_type,
                .name = name,
            });
        }
    }
    return out.toOwnedSlice();
}

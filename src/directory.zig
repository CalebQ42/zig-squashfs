const std = @import("std");

const InodeType = @import("inode.zig").Types;

const Header = extern struct {
    count: u32,
    block: u32,
    num: u32,
};

const RawEntry = packed struct {
    offset: u16,
    num_offset: u16,
    inode_type: InodeType,
    name_len: u16,
};

pub const DirEntry = struct {
    block: u32,
    offset: u16,
    inode_type: InodeType,
    num: u32,
    name: []const u8,

    pub fn deinit(self: DirEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn readEntries(alloc: std.mem.Allocator, reader: anytype, size: u32) !std.StringArrayHashMap(DirEntry) {
    var out: std.StringArrayHashMap(DirEntry) = .init(alloc);
    errdefer out.deinit();
    var cur_red: usize = 3; // size has 3 extra bytes (for . & ..).
    var red: usize = 0;
    var hdr: Header = undefined;
    var raw: RawEntry = undefined;
    while (cur_red < size) {
        red = try reader.readAll(std.mem.asBytes(&hdr));
        cur_red += red;
        try out.ensureUnusedCapacity(hdr.count + 1);
        for (0..hdr.count + 1) |_| {
            red = try reader.readAll(std.mem.asBytes(&raw));
            cur_red += red + raw.name_len + 1;
            const ent: DirEntry = .{ .block = hdr.block, .offset = raw.offset, .inode_type = raw.inode_type, .num = @intCast(hdr.num + raw.num_offset), .name = try alloc.alloc(u8, raw.name_len + 1) };
            errdefer ent.deinit(alloc);
            _ = try reader.readAll(ent.name);
            out.putAssumeCapacity(ent.name, ent);
        }
    }
    return out;
}

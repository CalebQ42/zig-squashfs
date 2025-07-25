const std = @import("std");

const InodeType = @import("inode.zig").Type;
const Compression = @import("superblock.zig").Compression;

const Header = extern struct { //use extern instead of packed, due to bit alignment
    count: u32,
    block: u32,
    num: u32,
};

const RawEntry = struct {
    offset: u16,
    num_offset: i16,
    type: InodeType,
    size: u16,
    name: []const u8,

    pub fn init(alloc: std.mem.Allocator, rdr: anytype) !RawEntry {
        var fixed: [8]u8 = undefined;
        _ = try rdr.read(&fixed);
        const size = std.mem.readInt(u16, fixed[6..8], .little);
        const name = try alloc.alloc(u8, size + 1);
        _ = try rdr.read(name);
        return .{
            .offset = std.mem.readInt(u16, fixed[0..2], .little),
            .num_offset = std.mem.readInt(i16, fixed[2..4], .little),
            .type = @enumFromInt(std.mem.readInt(u16, fixed[4..6], .little)),
            .size = size,
            .name = name,
        };
    }
};

pub const Entry = struct {
    block: u32,
    offset: u16,
    num: u32,
    type: InodeType,
    name: []const u8,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }
};

pub fn readDirectory(alloc: std.mem.Allocator, rdr: anytype, size: u32) ![]Entry {
    var entries: std.ArrayList(Entry) = .init(alloc);
    errdefer entries.deinit();
    var cur_red: u32 = 3; // dir size includes "." & "..", so its actual size is off by 3.
    var hdr: Header = undefined;
    while (cur_red < size) {
        _ = try rdr.read(std.mem.asBytes(&hdr));
        cur_red += 12;
        try entries.ensureUnusedCapacity(hdr.count + 1);
        for (0..hdr.count + 1) |_| {
            const raw_ent: RawEntry = try .init(alloc, rdr);
            cur_red += 9 + raw_ent.size;
            errdefer alloc.free(raw_ent.name);
            entries.appendAssumeCapacity(.{
                .block = hdr.block,
                .offset = raw_ent.offset,
                .num = @truncate(@abs(@as(i64, hdr.num) + raw_ent.num_offset)),
                .type = raw_ent.type,
                .name = raw_ent.name,
            });
        }
    }
    return entries.toOwnedSlice();
}

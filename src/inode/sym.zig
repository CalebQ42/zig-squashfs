const std = @import("std");
const Reader = std.Io.Reader;

pub const Symlink = struct {
    hard_links: u32,
    target: []const u8,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader) !Symlink {
        var buf: [8]u8 = undefined;
        try rdr.readSliceAll(&buf);
        const size = std.mem.readVarInt(u32, buf[4..], .little);
        const target = try alloc.alloc(u8, size);
        errdefer alloc.free(target);
        try rdr.readSliceEndian(u8, target, .little);
        return .{
            .hard_links = std.mem.readVarInt(u32, buf[0..4], .little),
            .target = target,
        };
    }
};

pub const ExtSymlink = struct {
    hard_links: u32,
    xattr_idx: u32,
    target: []const u8,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader) !ExtSymlink {
        var buf: [8]u8 = undefined;
        try rdr.readSliceAll(&buf);
        const size = std.mem.readVarInt(u32, buf[4..], .little);
        const target = try alloc.alloc(u8, size);
        errdefer alloc.free(target);
        try rdr.readSliceEndian(u8, target, .little);
        var xattr_idx: u32 = undefined;
        try rdr.readSliceEndian(u32, @ptrCast(&xattr_idx), .little);
        return .{
            .hard_links = std.mem.readVarInt(u32, buf[0..4], .little),
            .target = target,
            .xattr_idx = xattr_idx,
        };
    }
};

const std = @import("std");

pub const Symlink = struct {
    hard_links: u32,
    target_size: u32,
    target: []u8,
    pub fn read(alloc: std.mem.Allocator, reader: anytype) !Symlink {
        var buf: [8]u8 = undefined;
        _ = try reader.readAll(&buf);
        const siz = std.mem.readInt(u32, buf[4..], .little);
        const out: Symlink = .{
            .hard_links = std.mem.readInt(u32, buf[0..4], .little),
            .target_size = siz,
            .target = try alloc.alloc(u8, siz + 1),
        };
        _ = try reader.readAll(out.target);
        return out;
    }
    pub fn deinit(self: Symlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

pub const ExtSymlink = struct {
    hard_links: u32,
    target_size: u32,
    target: []u8,
    xattr_idx: u32,
    pub fn read(alloc: std.mem.Allocator, reader: anytype) !ExtSymlink {
        var buf: [8]u8 = undefined;
        _ = try reader.readAll(&buf);
        const siz = std.mem.readInt(u32, buf[4..], .little);
        var out: ExtSymlink = .{
            .hard_links = std.mem.readInt(u32, buf[0..4], .little),
            .target_size = siz,
            .target = try alloc.alloc(u8, siz + 1),
            .xattr_idx = 0,
        };
        _ = try reader.readAll(out.target);
        _ = try reader.readAll(std.mem.asBytes(&out.xattr_idx));
        return out;
    }
    pub fn deinit(self: ExtSymlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

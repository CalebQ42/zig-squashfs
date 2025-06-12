const std = @import("std");

pub const Sym = struct {
    hard_links: u32,
    //target_size: u32
    target: []const u8,

    const Self = @This();
    pub fn init(rdr: anytype, alloc: std.mem.Allocator) !Self {
        const buf: [8]u8 = undefined;
        _ = try rdr.read(&buf);
        const siz = std.mem.bytesToValue(u32, buf[4..8]);
        const target = try alloc.alloc(u8, siz);
        _ = rdr.read(target);
        return .{
            .hard_links = std.mem.bytesToValue(u32, buf[0..4]),
            .target = target,
        };
    }
    pub fn definit(self: Self, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};
pub const ExtSym = struct {
    hard_links: u32,
    //target_size: u32
    target: []const u8,
    xattr_idx: u32,

    const Self = @This();
    pub fn init(rdr: anytype, alloc: std.mem.Allocator) !Self {
        const buf: [8]u8 = undefined;
        _ = try rdr.read(&buf);
        const siz = std.mem.bytesToValue(u32, buf[4..8]);
        const target = try alloc.alloc(u8, siz);
        _ = rdr.read(target);
        const buf2: [4]u8 = undefined;
        _ = rdr.read(buf2);
        return .{
            .hard_links = std.mem.bytesToValue(u32, buf[0..4]),
            .target = target,
            .xattr_idx = std.mem.bytesToValue(u32, &buf2),
        };
    }
    pub fn definit(self: Self, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

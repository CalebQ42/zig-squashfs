const std = @import("std");
const io = std.io;

pub const SymInode = struct {
    hard_links: u32,
    size: u32,
    target: []const u8,

    pub fn init(alloc: std.mem.Allocator, rdr: io.AnyReader) !SymInode {
        const fixed_buf = [_]u8{0} ** 8;
        _ = try rdr.readAll(&fixed_buf);
        const size = std.mem.bytesToValue(u32, fixed_buf[4..]);
        const target = try alloc.alloc(u8, size);
        _ = try rdr.readAll(target);
        return .{
            .hard_links = std.mem.bytesToValue(u32, fixed_buf[0..4]),
            .size = size,
            .target = target,
        };
    }
    pub fn deinit(self: SymInode, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

pub const ExtSymInode = struct {
    hard_links: u32,
    size: u32,
    target: []const u8,
    xattr_idx: u32,

    pub fn init(alloc: std.mem.Allocator, rdr: io.AnyReader) !ExtSymInode {
        const fixed_buf = [_]u8{0} ** 8;
        _ = try rdr.readAll(&fixed_buf);
        const size = std.mem.bytesToValue(u32, fixed_buf[4..]);
        const target = try alloc.alloc(u8, size);
        _ = try rdr.readAll(target);
        return .{
            .hard_links = std.mem.bytesToValue(u32, fixed_buf[0..4]),
            .size = size,
            .target = target,
            .xattr_idx = rdr.readInt(u32, std.builtin.Endian.little),
        };
    }
    pub fn deinit(self: ExtSymInode, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

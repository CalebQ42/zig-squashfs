const std = @import("std");
const Reader = std.Io.Reader;

pub const Symlink = struct {
    hard_links: u32,
    target: []const u8,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader) !Symlink {
        var start: [8]u8 = undefined;
        try rdr.readSliceEndian(u8, &start, .little);
        const target_size = std.mem.readInt(u32, start[4..8], .little);
        const target = try alloc.alloc(u8, target_size + 1);
        errdefer alloc.free(target);
        try rdr.readSliceEndian(u8, target, .little);
        return .{
            .hard_links = std.mem.readInt(u32, start[0..4], .little),
            .target = target,
        };
    }

    pub fn deinit(self: Symlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

pub const ExtSymlink = struct {
    hard_links: u32,
    target: []const u8,
    xattr_idx: u32,

    pub fn read(alloc: std.mem.Allocator, rdr: *Reader) !ExtSymlink {
        var start: [8]u8 = undefined;
        try rdr.readSliceEndian(u8, &start, .little);
        const target_size = std.mem.readInt(u32, start[4..8], .little);
        const target = try alloc.alloc(u8, target_size + 1);
        errdefer alloc.free(target);
        try rdr.readSliceEndian(u8, target, .little);
        var xattr_idx: u32 = undefined;
        try rdr.readSliceEndian(u32, @ptrCast(&xattr_idx), .little);
        return .{
            .hard_links = std.mem.readInt(u32, start[0..4], .little),
            .target = target,
            .xattr_idx = xattr_idx,
        };
    }

    pub fn deinit(self: ExtSymlink, alloc: std.mem.Allocator) void {
        alloc.free(self.target);
    }
};

pub const Dev = packed struct {
    hard_links: u32,
    dev: u32,

    pub fn read(rdr: *Reader) !Dev {
        var d: Dev = undefined;
        try rdr.readSliceEndian(Dev, @ptrCast(&d), .little);
        return d;
    }
};

pub const ExtDev = packed struct {
    hard_links: u32,
    dev: u32,
    xattr_idx: u32,

    pub fn read(rdr: *Reader) !ExtDev {
        var d: ExtDev = undefined;
        try rdr.readSliceEndian(ExtDev, @ptrCast(&d), .little);
        return d;
    }
};

pub const IPC = packed struct {
    hard_links: u32,

    pub fn read(rdr: *Reader) !IPC {
        var d: IPC = undefined;
        try rdr.readSliceEndian(IPC, @ptrCast(&d), .little);
        return d;
    }
};

pub const ExtIPC = packed struct {
    hard_links: u32,
    xattr_idx: u32,

    pub fn read(rdr: *Reader) !ExtIPC {
        var d: ExtIPC = undefined;
        try rdr.readSliceEndian(ExtIPC, @ptrCast(&d), .little);
        return d;
    }
};

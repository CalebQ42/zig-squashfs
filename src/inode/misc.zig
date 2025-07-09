const std = @import("std");

pub const Symlink = struct {
    hard_link: u32,
    // size: u32,
    target: []const u8,

    pub fn init(rdr: anytype, alloc: std.mem.Allocator) !Symlink {
        var fixed: [8]u8 = undefined;
        _ = try rdr.read(&fixed);
        const size = std.mem.readInt(u32, fixed[4..8], .little);
        const target = alloc.alloc(u8, size);
        errdefer alloc.free(target);
        _ = try rdr.read(target);
        return .{
            .hard_link = std.mem.readInt(u32, fixed[0..4], .little),
            .target = target,
        };
    }
};

pub const ExtSymlink = struct {
    hard_link: u32,
    // size: u32,
    target: []const u8,
    xattr_idx: u32,

    pub fn init(rdr: anytype, alloc: std.mem.Allocator) !ExtSymlink {
        var fixed: [8]u8 = undefined;
        _ = try rdr.read(&fixed);
        const size = std.mem.readInt(u32, fixed[4..8], .little);
        const target = alloc.alloc(u8, size);
        errdefer alloc.free(target);
        _ = try rdr.read(target);
        var xattr_idx: u32 = 0;
        _ = try rdr.read(std.mem.asBytes(&xattr_idx));
        return .{
            .hard_link = std.mem.readInt(u32, fixed[0..4], .little),
            .target = target,
            .xattr_idx = xattr_idx,
        };
    }
};

pub const Dev = packed struct {
    hard_link: u32,
    device: u32,

    pub fn init(rdr: anytype) !Dev {
        const out: Dev = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtDev = packed struct {
    hard_link: u32,
    device: u32,
    xattr_idx: u32,

    pub fn init(rdr: anytype) !ExtDev {
        const out: ExtDev = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const IPC = packed struct {
    hard_link: u32,

    pub fn init(rdr: anytype) !IPC {
        const out: IPC = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtIPC = packed struct {
    hard_link: u32,
    xattr_idx: u32,

    pub fn init(rdr: anytype) !ExtIPC {
        const out: ExtIPC = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

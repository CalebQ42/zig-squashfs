const std = @import("std");

pub const Dev = packed struct {
    hard_links: u32,
    dev: u32,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtDev = packed struct {
    hard_links: u32,
    dev: u32,
    xattr_idx: u32,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const IPC = packed struct {
    hard_links: u32,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

pub const ExtIPC = packed struct {
    hard_links: u32,
    xattr_idx: u32,

    const Self = @This();
    pub fn init(rdr: anytype) !Self {
        const out: Self = undefined;
        _ = try rdr.read(std.mem.asBytes(&out));
        return out;
    }
};

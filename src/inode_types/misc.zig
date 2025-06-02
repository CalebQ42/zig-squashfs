const std = @import("std");

pub const Device = packed struct {
    hard_links: u32,
    dev: u32,
    pub fn read(reader: anytype) !Device {
        var out: Device = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&out)));
        return out;
    }
};
pub const ExtDevice = packed struct {
    hard_links: u32,
    dev: u32,
    xattr_idx: u32,
    pub fn read(reader: anytype) !ExtDevice {
        var out: ExtDevice = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&out)));
        return out;
    }
};
pub const IPC = packed struct {
    hard_links: u32,
    pub fn read(reader: anytype) !IPC {
        var out: IPC = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&out)));
        return out;
    }
};
pub const ExtIPC = packed struct {
    hard_links: u32,
    xattr_idx: u32,
    pub fn read(reader: anytype) !ExtIPC {
        var out: ExtIPC = undefined;
        _ = try reader.readAll(@alignCast(std.mem.asBytes(&out)));
        return out;
    }
};

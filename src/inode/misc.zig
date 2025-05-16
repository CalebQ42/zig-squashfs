const std = @import("std");
const io = std.io;

pub const DeviceInode = packed struct {
    hard_links: u32,
    device: u32,

    pub fn init(rdr: io.AnyReader) !DeviceInode {
        return rdr.readStruct(DeviceInode);
    }
};

pub const ExtDeviceInode = packed struct {
    hard_links: u32,
    device: u32,
    xattr_idx: u32,

    pub fn init(rdr: io.AnyReader) !ExtDeviceInode {
        return rdr.readStruct(ExtDeviceInode);
    }
};

pub const IPCInode = packed struct {
    hard_links: u32,

    pub fn init(rdr: io.AnyReader) !IPCInode {
        return rdr.readStruct(IPCInode);
    }
};

pub const ExtIPCInode = packed struct {
    hard_links: u32,
    xattr_idx: u32,

    pub fn init(rdr: io.AnyReader) !ExtIPCInode {
        return rdr.readStruct(ExtIPCInode);
    }
};

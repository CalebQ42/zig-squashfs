const io = @import("std").io;

pub const DeviceInode = packed struct {
    hard_links: u32,
    device: u32,
};

pub const ExtDeviceInode = packed struct {
    hard_links: u32,
    device: u32,
    xattr_index: u32,
};

pub const IPCInode = packed struct {
    hard_links: u32,
};

pub const ExtIPCInode = packed struct {
    hard_links: u32,
    xattr_index: u32,
};

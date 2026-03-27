const Reader = @import("std").Io.Reader;

pub const Device = packed struct {
    hard_links: u32,
    device: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

pub const ExtDevice = packed struct {
    hard_links: u32,
    device: u32,
    xattr_idx: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

pub const Ipc = packed struct {
    hard_links: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

pub const ExtIpc = packed struct {
    hard_links: u32,
    xattr_idx: u32,

    const Self = @This();

    pub fn read(rdr: *Reader) !Self {
        var new: Self = undefined;
        try rdr.readSliceEndian(Self, @ptrCast(&new), .little);
        return new;
    }
};

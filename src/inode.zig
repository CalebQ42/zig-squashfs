const std = @import("std");

pub const Ref = packed struct {
    offset: u16,
    block: u32,
    _: u16,
};

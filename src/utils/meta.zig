const std = @import("std");

const Decomp = @import("../decomp.zig");

const MetadataReader = @This();

data: []u8,
decomp: Decomp.Fn,

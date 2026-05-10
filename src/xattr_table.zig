const std = @import("std");

const LookupTable = @import("lookup_table.zig");
const Decompressor = @import("util/decompressor.zig");
const OffsetFile = @import("util/offset_file.zig");

const XattrTable = @This();

// Types

pub const Xattr = struct {
    key: [:0]const u8,
    value: []const u8,
};

// Stateless

pub fn statelessLookup() ![]Xattr {}

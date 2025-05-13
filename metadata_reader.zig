const std = @import("std");

const MetadataHeader = packed struct {
    compressed: bool,
    size: u15,
};

const MetadataReader = struct {
    rdr: std.io.AnyReader,
    curBlock: []const u8,
};

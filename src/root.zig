const std = @import("std");

pub const Reader = @import("reader.zig").Reader;

pub const FileReader = Reader(std.fs.File);

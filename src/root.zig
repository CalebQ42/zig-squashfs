const std = @import("std");

pub const Reader = @import("reader.zig").Reader;
pub const ExtractionOptions = @import("extract_options.zig");

pub const FileReader = Reader(std.fs.File);

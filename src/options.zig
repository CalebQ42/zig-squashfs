//! Options for file/directory extraction.

const std = @import("std");
const Writer = std.Io.Writer;

const ExtractionOptions = @This();

/// Don't set the file's permissions after extraction
ignorePermissions: bool = false,
/// Don't set the file's owner after extraction.
ignoreOwner: bool = false,
/// Replace symlinks with their target.
dereferenceSymlinks: bool = false,

log_level: std.log.Level = .err,
// /// If options verbose and verboseWriter not set, logs are printed to stdout.
// verboseWriter: ?*Writer = null,

pub const Default: ExtractionOptions = .{};
pub const VerboseDefault: ExtractionOptions = .{ .log_level = .debug };

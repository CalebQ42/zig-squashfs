//! Options for file/directory extraction.

const std = @import("std");
const Writer = std.Io.Writer;

const ExtractionOptions = @This();

/// Force single-threaded extraction. Io.Threaded.global_single_threaded also works.
single_threaded: bool = false,
/// Don't set the file's owner, permissions, & modify time after extraction.
ignore_permissions: bool = false,
/// Don't set xattr values.
ignore_xattr: bool = false,
/// Replace symlinks with their target. Currently doesn't do anything.
dereference_symlinks: bool = false,
/// Verbose logging. If true, verbose_writer must be set
verbose: bool = false,
/// Where to print verbose log.
verbose_writer: ?*Writer = null,

pub const defaultSingleThreaded: ExtractionOptions = .{ .single_threaded = true };
pub const default: ExtractionOptions = .{};

pub fn VerboseDefault(wrt: *Writer) !ExtractionOptions {
    return .{
        .verbose = true,
        .verbose_writer = wrt,
        .threads = try std.Thread.getCpuCount(),
    };
}

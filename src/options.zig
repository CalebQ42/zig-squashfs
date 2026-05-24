//! Options for file/directory extraction.

const std = @import("std");
const Writer = std.Io.Writer;

const ExtractionOptions = @This();

/// Extract single-threaded only.
/// Though not necessary if using Threaded.single_threaded,
/// setting single_threaded is more efficient.
single_threaded: bool = false,
/// Don't set the file's owner & permissions after extraction
ignore_permissions: bool = false,
/// Don't set xattr values. Currently xattrs are never set anyway.
ignore_xattr: bool = false,
/// Replace symlinks with their target.
dereference_symlinks: bool = false,
/// Verbose logging. If true, verbose_writer must be set
verbose: bool = false,
/// Where to print verbose log.
verbose_writer: ?*Writer = null,

pub const default: ExtractionOptions = .{};
pub const default_single_threaded: ExtractionOptions = .{ .single_threaded = true };

pub fn VerboseDefault(wrt: *Writer) !ExtractionOptions {
    return .{
        .verbose = true,
        .verbose_writer = wrt,
    };
}

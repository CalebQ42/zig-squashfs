//! Options for file/directory extraction.

const std = @import("std");
const Writer = std.Io.Writer;

const ExtractionOptions = @This();

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

pub const Default: ExtractionOptions = .{};
pub fn VerboseDefault(wrt: *Writer) ExtractionOptions {
    return .{
        .verbose = true,
        .verbose_writer = wrt,
    };
}

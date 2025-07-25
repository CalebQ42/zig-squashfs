const std = @import("std");

const Self = @This();

/// Replace symlinks with their targets
dereference_symlinks: bool = false,
/// Always extract a symlink's target if it's part of the archive.
/// May result in the symlink's target being changed.
unbreak_symlinks: bool = false,
/// Do not set file's permissions & owner when extracted.
ignore_permissions: bool = false,
/// Verbose logging
verbose: bool = false,
/// Verbose logging writer. If not set, stdout is used.
verbose_logger: std.io.AnyWriter = std.io.getStdOut().writer().any(),
/// Number of threads used during extraction. Defualts to std.Thread.getCpuCount().
thread_count: usize,

pub fn init() !Self {
    return .{
        .thread_count = try std.Thread.getCpuCount(),
    };
}

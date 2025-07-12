const std = @import("std");

const Self = @This();

/// Replace symlinks with their targets
dereference_symlinks: bool = false,
/// Always extract a symlink's target if it's part of the archive.
/// May result in the symlink's target being changed.
unbreak_symlinks: bool = false,
/// Do not set file's permissions & owner when extracted.
ignore_permissions: bool = false,

// max_memory: u64,

pol: std.Thread.Pool = undefined,

pub fn init(alloc: std.mem.Allocator, thread_count: u16) !Self {
    var out: Self = .{};
    out.pol.init(.{
        .allocator = alloc,
        .n_jobs = thread_count,
    });
    return out;
}

const std = @import("std");
const Writer = std.Io.Writer;

const Options = @This();

verbose: bool = false,
verbose_writer: ?*Writer = null,

ignore_permissions: bool = false,
ignore_xattr: bool = false,

dereference_symlink: bool = false,

pub const default: Options = .{};
pub fn verboseDefault(wrt: *Writer) Options {
    return .{
        .verbose = true,
        .verbose_writer = wrt,
    };
}

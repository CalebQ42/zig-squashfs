const std = @import("std");

const ToRead = @import("to_read.zig").ToRead;

/// A simple wrapper around a type with the pread([]u8, u64) function.
/// Provides a couple useful utility functions.
pub fn PRead(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        rdr: T,
        offset: u64,

        pub fn init(rdr: T, offset: u64) Self {
            return .{
                .rdr = rdr,
                .offset = offset,
            };
        }

        pub fn pread(self: Self, buf: []u8, offset: u64) !usize {
            return self.rdr.pread(buf, self.offset + offset);
        }
        pub fn readerAt(self: Self, offset: u64) ToRead(T) {
            return .init(self.rdr, self.offset + offset);
        }
    };
}

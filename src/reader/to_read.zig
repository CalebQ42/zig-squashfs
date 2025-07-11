const std = @import("std");

pub fn ToRead(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        rdr: T,
        offset: u64,

        pub fn init(rdr: T, init_offset: u64) Self {
            return .{
                .rdr = rdr,
                .offset = init_offset,
            };
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            const red = try self.rdr.pread(buf, self.offset);
            self.offset += red;
            return red;
        }
    };
}

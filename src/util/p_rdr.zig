const std = @import("std");

pub fn PRdr(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        rdr: T,
        offset: u64,

        pub fn init(rdr: T, offset: u64) Self {
            return .{ .rdr = rdr, .offset = offset };
        }

        pub fn pread(self: Self, dat: []u8, offset: u64) !usize {
            return self.rdr.pread(dat, offset + self.offset);
        }

        pub fn readerAt(self: Self, offset: u64) Reader(T) {
            return .{ .rdr = self, .offset = offset + self.offset };
        }
    };
}

pub fn Reader(comptime T: type) type {
    return struct {
        const Self = @This();

        rdr: T,
        offset: u64,

        pub fn read(self: *Self, dat: []u8) !usize {
            const red = try self.pread(dat, self.offset);
            self.offset += red;
            return red;
        }

        const GenericReader = std.io.GenericReader(*Self, anyerror, read);

        pub fn reader(self: *Self) GenericReader {
            return .{ .context = self };
        }
    };
}

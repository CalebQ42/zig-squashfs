const std = @import("std");

pub fn ToRead(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        pub const Error = anyerror;

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
        pub fn readAll(self: *Self, buf: []u8) !usize {
            var cur_red = try self.read(buf);
            if (cur_red == 0) return cur_red;
            var res: usize = 0;
            while (cur_red < buf.len) {
                res = try self.read(buf[cur_red..]);
                if (res == 0) break;
                cur_red += res;
            }
            return cur_red;
        }
        pub fn reader(self: anytype) std.io.Reader(*Self, anyerror, read) {
            return .{
                .context = @constCast(self),
            };
        }
    };
}

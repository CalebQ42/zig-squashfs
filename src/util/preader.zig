const std = @import("std");

pub fn PReader(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        p_rdr: T,
        offset: u64,

        pub fn init(p_rdr: T, offset: u64) Self {
            return .{
                .p_rdr = p_rdr,
                .offset = offset,
            };
        }

        pub fn pread(self: Self, buf: []u8, offset: u64) !usize {
            return self.p_rdr.pread(buf, self.offset + offset);
        }
        pub fn preadAll(self: Self, buf: []u8, offset: u64) !usize {
            if (comptime std.meta.hasFn(T, "preadAll")) {
                return self.p_rdr.preadAll(buf, self.offset + offset);
            }
            var cur_red: usize = 0;
            var red: usize = 0;
            while (cur_red < buf.len) {
                red = try self.pread(buf[cur_red..], offset + cur_red);
                if (red == 0) break;
                cur_red += red;
            }
            return cur_red;
        }

        pub fn readerAt(self: Self, offset: u64) OffsetReader {
            return .{
                .p_rdr = self.p_rdr,
                .curOffset = self.offset + offset,
            };
        }

        const OffsetReader = struct {
            p_rdr: T,
            cur_offset: u64,

            pub fn read(self: *OffsetReader, buf: []u8) !usize {
                const red = try self.p_rdr.pread(buf, self.offset);
                self.cur_offset += red;
                return red;
            }
            pub fn readAll(self: *OffsetReader, buf: []u8) !usize {
                if (comptime std.meta.hasFn(T, "preadAll")) {
                    const red = try self.p_rdr.preadAll(buf, self.offset);
                    self.cur_offset += red;
                    return red;
                }
                var cur_red: usize = 0;
                var red: usize = 0;
                while (cur_red < buf.len) {
                    red = try self.read(buf[cur_red..]);
                    if (red == 0) break;
                    cur_red += red;
                }
                return cur_red;
            }
        };
    };
}

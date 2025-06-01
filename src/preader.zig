const mem = @import("std").mem;

pub fn PReader(
    comptime Context: type,
    comptime ErrorType: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) ErrorType!usize,
) type {
    return struct {
        const Self = @This();

        rdr: Context,
        initOffset: u64 = 0,

        pub fn init(rdr: Context) Self {
            return .{
                .rdr = rdr,
            };
        }
        /// Creates the PReader with an additional offset that is applied to all calls.
        pub fn initWithOffset(rdr: Context, offset: u64) Self {
            return .{
                .rdr = rdr,
                .initOffset = offset,
            };
        }
        pub fn pread(self: Self, bytes: []u8, offset: u64) ErrorType!usize {
            return preadFn(self.rdr, bytes, offset + self.initOffset);
        }
        pub fn preadStruct(self: Self, comptime T: type, offset: u64) ErrorType!T {
            const bytes: [@sizeOf(T)]u8 = undefined;
            var totalRead: usize = 0;
            while (totalRead < @sizeOf(T)) {
                const red = try self.pread(bytes[totalRead..], offset);
                totalRead += red;
            }
            return mem.bytesToValue(T, bytes);
        }
    };
}

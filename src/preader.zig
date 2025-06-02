const std = @import("std");
const io = std.io;

pub fn PReader(
    comptime Context: type,
    comptime Error: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) Error!usize,
) type {
    return struct {
        const Self = @This();
        pub const Reader = OffsetReader(Context, Error, preadFn);

        ctx: Context,
        offset: u64,

        pub fn init(ctx: Context) Self {
            return .{
                .ctx = ctx,
            };
        }
        pub fn initWOffset(ctx: Context, offset: u64) Self {
            return .{
                .ctx = ctx,
                .offset = offset,
            };
        }
        pub fn preadAll(self: Self, buf: []u8, offset: u64) Error!usize {
            var total_red: usize = 0;
            while (total_red < buf.len) {
                const red = try preadFn(self.ctx, buf[total_red..], self.offset + offset + total_red);
                if (red == 0) break;
                total_red += red;
            }
            return total_red;
        }
        pub fn preadStruct(self: Self, comptime T: type, offset: u64) Error!T {
            comptime std.debug.assert(@typeInfo(T).@"struct".layout != .auto);
            const out: T = undefined;
            _ = try self.preadAll(std.mem.asBytes(&out), offset);
            return out;
        }
        pub fn readerAt(self: Self, offset: u64) Reader {
            return .init(self.ctx, self.offset + offset);
        }
    };
}

pub fn OffsetReader(
    comptime Context: type,
    comptime ErrorType: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) ErrorType!usize,
) type {
    return struct {
        const Self = @This();
        pub const Error = ErrorType;

        ctx: Context,
        offset: u64,

        pub fn init(ctx: Context, init_offset: u64) Self {
            return .{
                .ctx = ctx,
                .offset = init_offset,
            };
        }
        pub fn read(self: *Self, buf: []u8) ErrorType!usize {
            if (preadFn(self.ctx, buf, self.offset)) |siz| {
                self.offset += siz;
                return siz;
            } else |err| {
                return err;
            }
        }
        pub fn readAll(self: *Self, buf: []u8) ErrorType!usize {
            var total_red: usize = 0;
            while (total_red < buf.len) {
                const red = try self.read(buf[total_red..]);
                if (red == 0) break;
                total_red += red;
            }

            return total_red;
        }
    };
}

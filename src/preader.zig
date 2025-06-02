const std = @import("std");
const io = std.io;

pub fn PReader(
    comptime Context: type,
    comptime Error: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) Error!usize,
) type {
    return struct {
        const Self = @This();

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
            const total_red: usize = 0;
            while (total_red < buf.len) {
                const red = preadFn(self.ctx, buf, self.offset + offset);
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
        pub fn readerAt(self: Self, offset: u64) OffsetReader(Context, Error, preadFn) {
            return .init(self.ctx, self.offset + offset);
        }
    };
}

pub fn OffsetReader(
    comptime Context: type,
    comptime Error: type,
    comptime preadFn: fn (ctx: Context, buf: []u8, offset: u64) Error!usize,
) type {
    return struct {
        const Self = @This();

        ctx: Context,
        offset: u64,

        pub fn init(ctx: Context, init_offset: u64) Self {
            return .{
                .ctx = ctx,
                .offset = init_offset,
            };
        }
        pub fn read(self: *Self, buf: []u8) Error!usize {
            if (preadFn(self.ctx, buf, self.offset)) |siz| {
                self.offset += siz;
                return siz;
            } else |err| {
                return err;
            }
        }
    };
}

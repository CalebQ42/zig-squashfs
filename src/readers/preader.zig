const std = @import("std");
const io = std.io;

pub fn PReader(
    comptime Context: type,
) type {
    comptime std.debug.assert(std.meta.hasFn(Context, "pread"));
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

        pub fn pread(self: Self, buf: []u8, offset: u64) !usize {
            return self.ctx.pread(buf, offset + self.offset);
        }
        pub fn preadAll(self: Self, buf: []u8, offset: u64) !usize {
            comptime if (std.meta.hasFn(Context, "preadAll")) {
                return self.ctx.preadAll(buf, offset + self.offset);
            } else {
                var total_red: usize = 0;
                while (total_red < buf.len) {
                    const red = try self.ctx.pread(buf[total_red..], self.offset + offset + total_red);
                    if (red == 0) break;
                    total_red += red;
                }
                return total_red;
            };
        }
        pub fn preadStruct(self: Self, comptime T: type, offset: u64) !T {
            comptime std.debug.assert(@typeInfo(T).@"struct".layout != .auto);
            const out: T = undefined;
            _ = try self.preadAll(std.mem.asBytes(&out), offset);
            return out;
        }
        pub fn readerAt(self: Self, offset: u64) OffsetReader {
            return .init(self.ctx, self.offset + offset);
        }

        pub const OffsetReader = struct {
            pub const Error = anyerror;

            ctx: Context,
            offset: u64,

            pub fn init(ctx: Context, init_offset: u64) OffsetReader {
                return .{
                    .ctx = ctx,
                    .offset = init_offset,
                };
            }
            pub fn read(self: *OffsetReader, buf: []u8) !usize {
                const red = try self.ctx.pread(buf, self.offset);
                self.offset += red;
                return red;
            }
            pub fn readAll(self: *OffsetReader, buf: []u8) !usize {
                comptime if (std.meta.hasFn(Context, "preadAll")) {
                    const red = try self.ctx.preadAll(buf, self.offset);
                    self.offset += red;
                    return red;
                } else {
                    var total_red: usize = 0;
                    while (total_red < buf.len) {
                        const red = try self.read(buf[total_red..]);
                        if (red == 0) break;
                        total_red += red;
                    }
                    return total_red;
                };
            }
        };
    };
}

const std = @import("std");

const PReader = @import("util/preader.zig").Preader;

pub fn SfsReader(comptime T: type) type {
    comptime std.debug.assert(std.meta.hasFn(T, "pread"));
    return struct {
        const Self = @This();

        p_rdr: PReader(T),

        pub fn init(p_rdr: T, offset: u64) !Self {
            return .{
                .p_rdr = .init(p_rdr, offset),
            };
        }
    };
}

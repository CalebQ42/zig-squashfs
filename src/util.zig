const std = @import("std");
const builtin = @import("builtin");

pub fn readValue(comptime T: type, bytes: []u8) T {
    var res = std.mem.bytesToValue(T, bytes);
    if (builtin.cpu.arch.endian() != .little) {
        switch (@typeInfo(T)) {
            .@"enum" => res = std.mem.nativeToLittle(@typeInfo(T).@"enum".tag_type, res),
            .@"struct" => std.mem.byteSwapAllFields(T, &res),
            .int => res = std.mem.nativeToLittle(T, res),
            .array => std.mem.byteSwapAllElements(@typeInfo(T).array.child, res),
            else => unreachable,
        }
    }
    return res;
}

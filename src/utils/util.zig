const std = @import("std");
const builtin = @import("builtin");

pub fn readValue(comptime T: type, bytes: []u8) T {
    var res = std.mem.bytesToValue(T, bytes);
    if (comptime builtin.cpu.arch.endian() != .little) {
        switch (@typeInfo(T)) {
            .@"enum" => res = std.mem.nativeToLittle(@typeInfo(T).@"enum".tag_type, res),
            .@"struct" => |s| {
                if (s.layout == .@"packed") {
                    res = @bitCast(std.mem.nativeToLittle(s.backing_integer.?, @bitCast(res)));
                } else {
                    std.mem.byteSwapAllFields(T, &res);
                }
            },
            .int => res = std.mem.nativeToLittle(T, res),
            .array => |a| std.mem.byteSwapAllElements(a.child, res),
            else => unreachable,
        }
    }
    return res;
}
pub fn readValueRdr(comptime T: type, rdr: *std.Io.Reader) !T {
    var tmp: [@sizeOf(T)]u8 = undefined;
    try rdr.readSliceAll(&tmp);

    return readValue(T, &tmp);
}

const std = @import("std");

pub fn Channel(
    comptime T: type,
    // comptime Size: u32,
) type {
    return struct {
        const Self = Self();

        mut: std.Thread.Mutex,
        list: std.SinglyLinkedList(T),

        pub fn init() Self {
            return .{
                .mut = .{},
                .list = .{},
            };
        }
    };
}

const std = @import("std");

pub fn MemPool(
    comptime T: type,
) type {
    return struct {
        const Self = @This();

        alloc: std.mem.Allocator,
        mut: std.Thread.Mutex,
        list: std.ArrayList(*T),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .mut = .{},
                .list = .init(alloc),
            };
        }
        pub fn deinit(self: *Self) void {
            self.list.deinit();
        }

        pub fn get(self: *Self) !*T {
            self.mut.lock();
            defer self.mut.unlock();
            return self.list.pop() orelse try self.alloc.create(T);
        }
        pub fn put(self: *Self, item: *T) !void {
            return self.list.append(item);
        }
    };
}

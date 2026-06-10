const std = @import("std");
const Io = std.Io;

const Decomp = @import("decomp.zig");

pub fn Table(comptime T: anytype) type {
    return struct {
        const VALUES_PER_BLOCK = 8192 / @sizeOf(T);

        const Self = @This();

        data: []u8,
        decomp: Decomp.Fn,

        table_start: u64,
        table_num: u32,

        pub fn init(alloc: std.mem.Allocator, table_start: u64, table_num: u32) Self {}
        pub fn deinit(self: *Self) void {}

        pub fn get(self: *Self, io: Io, idx: u32) !T {}
    };
}

pub fn ProtectedMap(comptime K: anytype, comptime T: anytype, comptime create_fn: anytype) type {
    std.debug.assert(std.meta.activeTag(@typeInfo(create_fn)) == .@"fn");

    const ret_info = @typeInfo(create_fn).@"fn".return_type;

    std.debug.assert(ret_info == T or
        (std.meta.activeTag(@typeInfo(ret_info)) == .error_union and @typeInfo(ret_info).error_union.payload == T));

    return struct {
        const Map = @This();

        alloc: std.mem.Allocator,

        map: std.AutoHashMap(K, ProtectedValue),
        mut: Io.RwLock = .init,

        pub fn init(alloc: std.mem.Allocator, default_value: T) Map {
            return .{
                .alloc = alloc,

                .map = .init(alloc),

                .default_value = default_value,
            };
        }
        pub fn deinit(self: *Map) void {}

        pub fn getOrPut(self: *Map, io: Io, key: K, create_fn_args: std.meta.ArgsTuple(create_fn)) !*T {
            {
                try self.mut.lockShared(io);
                defer self.mut.unlockShared(io);

                const value = self.map.getPtr(key);
                if (value != null) {
                    if (!value.?.filled.isSet())
                        value.?.filled.wait(io);
                    if (value.?.err != null) return value.?.err != null;
                    return value.?.value;
                }
            }
            try self.mut.lock(io);

            const res = self.map.getOrPut(key) catch |err| {
                self.mut.unlock(io);
                return err;
            };
            if (res.found_existing) {
                self.mut.unlock(io);
                return self.getOrPut(io, key, create_fn_args);
            }
            res.value_ptr.* = .{};
            defer res.value_ptr.filled.set(io);

            res.mut.unlock(io);

            self.mut.lockSharedUncancelable(io);
            defer self.mut.unlockShared(io);

            if (@TypeOf(CreateError) == void) {
                res.value_ptr.value = @call(.auto, create_fn, create_fn_args);
            } else {
                res.value_ptr.value = @call(.auto, create_fn, create_fn_args) catch |err| {
                    res.value_ptr.err = err;
                };
            }
        }

        // Map Types

        const CreateError: type = switch (@typeInfo(@typeInfo(create_fn).@"fn".return_type)) {
            .error_union => |e| e.error_set,
            else => void,
        };

        const ProtectedValue = struct {
            value: T = undefined,
            err: ?CreateError = null,
            filled: Io.Event = .unset,
        };
    };
}

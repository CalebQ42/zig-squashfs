const std = @import("std");
const Io = std.Io;

pub fn ProtectedMap(comptime K: anytype, comptime T: anytype, comptime create_fn: anytype) type {
    const fn_info = @typeInfo(@TypeOf(create_fn));
    std.debug.assert(std.meta.activeTag(fn_info) == .@"fn");

    const ret_info = fn_info.@"fn".return_type;

    std.debug.assert(ret_info != null);
    std.debug.assert(ret_info == T or
        (std.meta.activeTag(@typeInfo(ret_info.?)) == .error_union and @typeInfo(ret_info.?).error_union.payload == T));

    return struct {
        const Map = @This();

        alloc: std.mem.Allocator,

        map: std.AutoHashMap(K, ProtectedValue),
        mut: Io.RwLock = .init,

        pub fn init(alloc: std.mem.Allocator) Map {
            return .{
                .alloc = alloc,

                .map = .init(alloc),
            };
        }
        pub fn deinit(self: *Map) void {
            self.map.deinit();
        }

        pub fn getOrPut(self: *Map, io: Io, key: K, create_fn_args: std.meta.ArgsTuple(@TypeOf(create_fn))) Error!*T {
            {
                try self.mut.lockShared(io);
                const value = self.map.getPtr(key);
                self.mut.unlockShared(io);
                if (value != null) {
                    if (!value.?.filled.isSet()) {
                        self.mut.unlockShared(io);
                        defer self.mut.lockSharedUncancelable(io);

                        try value.?.filled.wait(io);
                    }
                    if (value.?.err != null) return value.?.err.?;
                    return &value.?.value;
                }
            }
            var value: *ProtectedValue = blk: {
                try self.mut.lock(io);
                defer self.mut.unlock(io);

                const res = try self.map.getOrPut(key);
                if (res.found_existing)
                    return self.getOrPut(io, key, create_fn_args);
                res.value_ptr.* = .{};
                break :blk res.value_ptr;
            };
            defer value.filled.set(io);

            value.value = if (@TypeOf(CreateError) == void)
                @call(.auto, create_fn, create_fn_args)
            else
                @call(.auto, create_fn, create_fn_args) catch |err| {
                    value.err = err;
                    return err;
                };

            return &value.value;
        }

        // Map Types

        pub const Error = error{ Canceled, OutOfMemory } ||
            if (@TypeOf(CreateError) == void) error{} else CreateError;

        const CreateError: type = switch (@typeInfo(ret_info.?)) {
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

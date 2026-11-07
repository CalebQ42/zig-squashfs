const std = @import("std");
const Io = std.Io;

/// A queue of shared, multi-threaded resources, attempting to create as few elements as possible.
pub fn ResourceQueue(T: anytype) type {
    return struct {
        queue: std.ArrayListUnmanaged(?T),
        cond: Io.Condition = .init,
        mut: Io.Mutex = .init,

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator, size: usize) !Self {
            var queue: std.ArrayListUnmanaged(?T) = try .initCapacity(alloc, size);
            queue.appendNTimesAssumeCapacity(null, size);

            return .{ .queue = queue };
        }
        /// Remember to manually deinit each non-null value in Queue.queue.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: Io) void {
            self.mut.lockUncancelable(io);
            self.queue.deinit(alloc);
        }

        /// Get a value of type T. If a value isn't available in the queue, but there is room for a new value, null is returned,
        /// Returns values in stack order (last in, first out).
        pub fn get(self: *Self, io: Io) !?T {
            try self.mut.lock(io);
            defer self.mut.unlock(io);

            var pop = self.queue.pop();
            while (pop == null) {
                try self.cond.wait(io, &self.mut);
                pop = self.queue.pop();
            }

            return pop.?;
        }
        /// Return a value of type T to the queue.
        pub fn put(self: *Self, io: Io, value: T) void {
            self.mut.lockUncancelable(io);
            self.queue.appendAssumeCapacity(value);
            self.mut.unlock(io);

            self.cond.signal(io);
        }
    };
}

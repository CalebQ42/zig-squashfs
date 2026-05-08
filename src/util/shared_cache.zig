const std = @import("std");
const Io = std.Io;
const Node = std.SinglyLinkedList.Node;

const SharedCache = @This();

pub const CACHE_SIZE = 1024 * 1024;

pub const BufferNode = struct {
    node: Node,
    cache: [CACHE_SIZE]u8,
};

alloc: std.mem.Allocator,

caches: std.ArrayList(BufferNode),
cache_queue: std.SinglyLinkedList,
queue_mut: Io.Mutex,

pub fn init(alloc: std.mem.Allocator, init_cache_size: u32) !SharedCache {
    const caches: std.ArrayList(BufferNode) = try .initCapacity(alloc, init_cache_size);
    var queue: std.SinglyLinkedList = .{};
    for (caches.items) |item|
        queue.prepend(&item.node);
    return .{
        .alloc = alloc,

        .caches = caches,
        .cache_queue = queue,
    };
}
pub fn deinit(self: *SharedCache) void {
    self.caches.deinit(self.alloc);
}

pub fn getCache(self: *SharedCache, io: Io) !*BufferNode {
    self.queue_mut.lock(io);
    const nxt = self.cache_queue.popFirst();
    self.queue_mut.unlock(io);
    if (nxt == null) {
        const new = try self.caches.addOne(self.alloc);
        new.* = .{
            .node = .{},
            .cache = undefined,
        };
        return new;
    }
    return @fieldParentPtr("node", nxt.?);
}
pub fn returnCache(self: *SharedCache, buf: *BufferNode) void {
    self.cache_queue.prepend(buf);
}

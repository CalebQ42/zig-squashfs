const std = @import("std");

const DecompMgr = @This();

pub const Compression = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};
const DecompThread = struct {
    thr: std.Thread = undefined,
    fut_atomic: std.atomic.Value(u32) = .init(0),
    fut: std.Thread.Futex = .{},

    fn start(self: *DecompThread, mgr: *DecompMgr) !void {
        self.thr = try std.Thread.spawn(.{}, thread, .{ self, mgr });
    }

    fn thread(self: *DecompThread, mgr: *DecompMgr) void {
        while (!mgr.closed) {
            self.fut.wait(&self.fut_atomic, 0);
            if (mgr.closed) return;
            if (self.fut_atomic.load(.acq_rel) == 0) continue; // Check for random wakeup.
            defer self.fut_atomic.store(0, .acq_rel);
        }
    }
};

const ThreadNode = std.SinglyLinkedList(DecompThread).Node;

alloc: std.mem.Allocator,
comp: Compression,

closed: bool = false,
to_start: usize,

thrs: []DecompThread,

thrs_queue: std.SinglyLinkedList(usize),
thrs_mut: std.Thread.Mutex = .{},
thrs_cond: std.Thread.Condition = .{},

pub fn init(alloc: std.mem.Allocator, thread_count: usize, comp: Compression) !DecompMgr {
    return .{
        .alloc = alloc,
        .comp = comp,
        .to_start = thread_count,
        .thrs = try alloc.alloc(DecompThread, thread_count),
    };
}
pub fn deinit(self: *DecompMgr) void {
    self.closed = true;
    for (self.threads) |*t| {
        t.fut_atomic.store(1, .acq_rel);
        t.thr.join();
    }
    self.alloc.free(self.threads);
}

pub fn decomp(self: *DecompMgr, alloc: std.mem.Allocator, dat: []u8) ![]u8 {
    var thr: usize = undefined;
    self.thrs_mut.lock();
    while (true) {
        errdefer self.thrs_mut.unlock();
        const node = self.thrs_queue.popFirst();
        if (node != null) {
            thr = node.?.data;
            break;
        }
        if (self.to_start > 0) {
            self.thrs[self.thrs.len - self.to_start] = .{};
            try self.thrs[self.thrs.len - self.to_start].start(self);
            thr = self.thrs.len - self.to_start;
            self.to_start -= 1;
            break;
        }
        self.thrs_cond.wait(self.thrs_mut);
    }
    self.thrs_mut.unlock();
    //TODO: Actually send data to the threads
}

fn decompThread(self: *DecompMgr) void {
    while (!self.closed) {}
}

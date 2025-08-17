const std = @import("std");

const DecmpMgr = @This();

pub const Compression = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};
pub const DecmpThread = struct {
    thr: std.Thread = undefined,
    fut_atomic: std.atomic.Value(u32) = .init(0),
    fut: std.Thread.Futex = .{},

    pub fn start(self: *DecmpThread, mgr: *DecmpMgr) !void {
        self.thr = try std.Thread.spawn(.{}, decompThread, .{mgr});
    }
};

alloc: std.mem.Allocator,
comp: Compression,

closed: bool = false,
to_start: usize,

threads: []std.Thread,

pub fn init(alloc: std.mem.Allocator, thread_count: u32, comp: Compression) !DecmpMgr {
    return .{
        .alloc = alloc,
        .comp = comp,
        .to_start = thread_count,
        .threads = try alloc.alloc(std.Thread, thread_count),
    };
}
pub fn deinit(self: DecmpMgr) void {
    self.closed = true;
    for (self.threads) |t| {
        t.join();
    }
    self.alloc.free(self.threads);
}

pub fn decomp(self: *DecmpMgr, alloc: std.mem.Allocator, dat: []u8) ![]u8 {}

fn decompThread(self: *DecmpMgr) void {
    while (!self.closed) {}
}

const std = @import("std");

const Futex = std.Thread.Futex;

const zlib = std.compress.zlib;
const lzma = std.compress.lzma;
const xz = std.compress.xz;
const zstd = std.compress.zstd;

pub const MgrErr = error{
    lzoUnsupported,
    lz4Unsupported,
    closed,
};

pub const CompType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};
const Thread = struct {
    idx: usize = 0,

    wrk: []u8 = &[0]u8{},
    out: []u8 = undefined,
    siz: anyerror!usize = 0,
    finish_atom: std.atomic.Value(u32) = .init(0),

    thr: std.Thread = undefined,
    atom: std.atomic.Value(u32) = .init(0),

    fn start(self: *Thread, mgr: *Mgr, idx: usize) !void {
        self.idx = idx;
        self.thr = try std.Thread.spawn(.{}, thread, .{ self, mgr });
    }

    fn submitWork(self: *Thread, wrk: []u8, out: []u8) void {
        self.wrk = wrk;
        self.out = out;
        self.finish_atom.store(0, .release);
        Futex.wake(&self.atom, 1);
    }
    fn finishWork(self: *Thread, mgr: *Mgr) void {
        self.wrk = &[0]u8{};
        mgr.mut.lock();
        mgr.queue.append(&mgr.threads[self.idx]);
        mgr.mut.unlock();
        mgr.cond.signal();
    }

    fn thread(self: *Thread, mgr: *Mgr) void {
        while (self.atom.raw == 0) {
            Futex.wait(&self.atom);
            if (self.wrk.len == 0 or self.atom.raw != 0) continue;
            defer self.finish_atom.store(1, .release);
            switch (mgr.comp) {
                .gzip => {
                    var decomp = zlib.decompressor(std.io.fixedBufferStream(self.wrk));
                    self.siz = decomp.read(self.out);
                },
                .lzma => {
                    var decomp = lzma.decompress(mgr.alloc, std.io.fixedBufferStream(self.wrk)) catch |err| {
                        self.siz = err;
                        continue;
                    };
                    defer decomp.deinit();
                    decomp.read(self.out);
                },
                .lzo => self.siz = MgrErr.lzoUnsupported,
                .xz => {
                    var decomp = xz.decompress(mgr.alloc, std.io.fixedBufferStream(self.wrk)) catch |err| {
                        self.siz = err;
                        continue;
                    };
                    defer decomp.deinit();
                    self.siz = decomp.read(self.out);
                },
                .lz4 => self.siz = MgrErr.lz4Unsupported,
                .zstd => {
                    var win: [1024 * 1024]u8 = undefined;
                    var decomp = zstd.decompressor(std.io.fixedBufferStream(self.wrk), .{ .window_buffer = &win });
                    self.siz = decomp.read(self.out);
                },
            }
        }
        self.siz = MgrErr.closed;
        self.finish_atom.store(1, .release);
    }
};

const Mgr = @This();

const ThreadNode = std.DoublyLinkedList(Thread).Node;

alloc: std.mem.Allocator,

closed: bool = false,
comp: CompType,
to_start: usize,

threads: []ThreadNode,
queue: std.DoublyLinkedList(Thread) = .{},
mut: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},

pub fn init(alloc: std.mem.Allocator, comp: CompType, thread_count: usize) !Mgr {
    return .{
        .alloc = alloc,
        .comp = comp,
        .to_start = thread_count,
        .threads = try alloc.alloc(ThreadNode, thread_count),
    };
}
pub fn deinit(self: *Mgr) void {
    self.closed = true;
    self.cond.broadcast();
    for (self.threads[self.to_start..]) |*t| {
        t.data.atom.store(1, .release);
        t.data.thr.join();
    }
    self.alloc.free(self.threads);
}

pub fn decompress(self: *Mgr, dat: []u8, out: []u8) !usize {
    if (self.closed) return MgrErr.closed;
    var thr: *Thread = undefined;
    self.mut.lock();
    while (!self.closed) {
        errdefer self.mut.unlock();
        var pop = self.queue.popFirst();
        if (pop != null) {
            thr = &pop.?.data;
            break;
        }
        if (self.to_start > 0) {
            self.to_start -= 1;
            self.threads[self.to_start] = .{ .data = .{} };
            try self.threads[self.to_start].data.start(self, self.to_start);
            thr = &self.threads[self.to_start].data;
            break;
        }
        self.cond.wait(&self.mut);
    }
    self.mut.unlock();
    if (self.closed) return MgrErr.closed;
    defer thr.finishWork(self);
    thr.submitWork(dat, out);
    while (thr.finish_atom.raw == 0) {
        Futex.wait(&thr.finish_atom, 0);
    }
    return thr.siz;
}

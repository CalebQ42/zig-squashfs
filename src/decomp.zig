const std = @import("std");
const compress = std.compress;
const Reader = std.Io.Reader;
const Thread = std.Thread;
const Futex = Thread.Futex;
const Mutex = Thread.Mutex;
const Condition = Thread.Condition;
const Node = std.DoublyLinkedList.Node;

const Atomic = std.atomic.Value(u32);

const DecompError = error{
    ThreadClosed,
    LzoUnsupported,
    Lz4Unsupported,
};

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const DecompThread = struct {
    mgr: *DecompMgr,

    /// Current thread status & signal value via Futex.
    /// 0 - Unstarted, 1 - Waiting, 2 - Working, 3 - Closed,
    status: Atomic = .{ .raw = 0 },
    thr: Thread = undefined,
    node: Node = .{},
    buf: []u8,

    dat: []u8 = &[0]u8{},
    rdr: ?*Reader = null,
    res: []u8 = &[0]u8{},
    res_size: anyerror!usize = 0,

    pub fn init(mgr: *DecompMgr) !DecompThread {
        return .{
            .mgr = mgr,
            .buf = switch (mgr.comp_type) {
                .gzip => try mgr.alloc.alloc(u8, compress.flate.max_window_len),
                .zstd => try mgr.alloc.alloc(u8, compress.zstd.default_window_len + compress.zstd.block_size_max),
                .lzma, .xz => &[0]u8{},
                else => unreachable,
            },
        };
    }

    pub fn close(self: *DecompThread) void {
        if (self.status.raw == 0) return;
        while (self.status.raw == 2) Futex.wait(&self.status, 2);
        self.status.store(3, .release);
        Futex.wake(&self.status, 1);
        self.thr.join();
    }

    pub fn submitData(self: *DecompThread, dat: []u8, res: []u8) anyerror!usize {
        if (self.status.raw == 3) return DecompError.ThreadClosed;
        if (self.status.raw == 0) {
            self.thr = try .spawn(.{}, thread, .{self});
        }
        self.dat = dat;
        defer self.dat = &[0]u8{};
        self.res = res;
        self.status.raw = 2;
        while (self.status.raw == 2) Futex.wait(&self.status, 2);
        return self.res_size;
    }
    pub fn submitReader(self: *DecompThread, rdr: *Reader, res: []u8) anyerror!usize {
        if (self.status.raw == 3) return DecompError.ThreadClosed;
        if (self.status.raw == 0) {
            self.thr = try .spawn(.{}, thread, .{self});
        }
        self.rdr = rdr;
        defer self.rdr = null;
        self.res = res;
        self.status.store(2, .release);
        Futex.wake(&self.status, 1);
        while (self.status.raw == 2) Futex.wait(&self.status, 2);
        return self.res_size;
    }

    pub fn thread(self: *DecompThread) void {
        const comp_type = self.mgr.comp_type;
        while (self.status.raw != 3) {
            while (self.status.raw == 1) Futex.wait(&self.status, 1);
            if (self.status.raw == 3) return;
            var dat_rdr: Reader = .fixed(self.dat);
            var rdr: *Reader = if (self.rdr != null) self.rdr.? else &dat_rdr;
            self.res_size = blk: switch (comp_type) {
                .gzip => {
                    var decomp_rdr = compress.flate.Decompress.init(rdr, .zlib, self.buf);
                    break :blk decomp_rdr.reader.readSliceShort(self.res) catch |err| {
                        break :blk decomp_rdr.err orelse err;
                    };
                },
                .lzma => {
                    var decomp_rdr = compress.lzma.decompress(self.mgr.alloc, rdr.adaptToOldInterface()) catch |err| {
                        break :blk err;
                    };
                    break :blk decomp_rdr.read(self.res);
                },
                .xz => {
                    var decomp_rdr = compress.xz.decompress(self.mgr.alloc, rdr.adaptToOldInterface()) catch |err| {
                        break :blk err;
                    };
                    break :blk decomp_rdr.read(self.res);
                },
                .zstd => {
                    var decomp_rdr = compress.zstd.Decompress.init(rdr, self.buf, .{});
                    break :blk decomp_rdr.reader.readSliceShort(self.res) catch |err| {
                        break :blk decomp_rdr.err orelse err;
                    };
                },
                else => unreachable,
            };
            const orig = self.status.swap(1, .release);
            Futex.wake(&self.status, 1);
            if (orig == 3) return;
        }
    }
};

const DecompMgr = @This();

alloc: std.mem.Allocator,
comp_type: CompressionType,
block_size: u32,

threads: []DecompThread,
queue: std.DoublyLinkedList = .{},
mut: Mutex = .{},
cond: Condition = .{},
to_start: usize,

pub fn init(alloc: std.mem.Allocator, comp_type: CompressionType, block_size: u32, threads: usize) !DecompMgr {
    return switch (comp_type) {
        .lzo => DecompError.LzoUnsupported,
        .lz4 => DecompError.Lz4Unsupported,
        else => .{
            .alloc = alloc,
            .comp_type = comp_type,
            .block_size = block_size,
            .threads = try alloc.alloc(DecompThread, threads),
            .to_start = threads,
        },
    };
}

pub fn deinit(self: DecompMgr) void {
    for (self.threads[self.to_start..]) |*t| {
        t.close();
    }
    self.alloc.free(self.threads);
}

pub fn decompSlice(self: *DecompMgr, dat: []u8, res: []u8) !usize {
    self.mut.lock();
    var thr: *DecompThread = undefined;
    var node = self.queue.popFirst();
    if (self.node != null) {
        self.mut.unlock();
        thr = @fieldParentPtr("node", node.?);
    } else blk: {
        defer self.mut.unlock();
        if (self.to_start > 0) {
            self.threads[self.to_start - 1] = .init(self);
            thr = &self.threads[self.to_start - 1];
            self.to_start -= 1;
            break :blk;
        }
        while (node == null) {
            self.cond.wait(&self.mut);
            node = self.queue.popFirst();
        }
        thr = @fieldParentPtr("node", node.?);
    }
    defer {
        self.queue.append(&thr.node);
        self.cond.signal();
    }
    return thr.submitData(dat, res);
}
pub fn decompReader(self: *DecompMgr, rdr: *Reader, res: []u8) !usize {
    self.mut.lock();
    var thr: *DecompThread = undefined;
    var node = self.queue.popFirst();
    if (node != null) {
        self.mut.unlock();
        thr = @fieldParentPtr("node", node.?);
    } else blk: {
        defer self.mut.unlock();
        if (self.to_start > 0) {
            self.threads[self.to_start - 1] = try .init(self);
            thr = &self.threads[self.to_start - 1];
            self.to_start -= 1;
            break :blk;
        }
        while (node == null) {
            self.cond.wait(&self.mut);
            node = self.queue.popFirst();
        }
        thr = @fieldParentPtr("node", node.?);
    }
    defer {
        self.queue.append(&thr.node);
        self.cond.signal();
    }
    return thr.submitReader(rdr, res);
}

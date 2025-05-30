const std = @import("std");

const Thread = std.Thread;

const Self = @This();

const Work = struct {
    /// actual work & cleanup.
    run: *const fn (*Work) void,
    /// skip the work, only cleanup.
    cleanup: *const fn (*Work) void,
};

alloc: std.mem.Allocator,
work: std.ArrayList(*Work),
mut: Thread.Mutex = .{},
cond: Thread.Condition = .{},
threads: []Thread,

running: bool = false,
waiting: bool = false,

pub fn init(alloc: std.mem.Allocator, threads: u16) !Self {
    return .{
        .alloc = alloc,
        .work = .init(alloc),
        .threads = try alloc.alloc(Thread, threads),
    };
}

pub fn start(self: *Self) !void {
    if (self.running) return;
    self.running = true;
    for (self.threads, 0..) |_, i| {
        std.debug.print("yon {}\n", .{i});
        self.threads[i] = try Thread.spawn(.{}, workThread, .{self});
    }
}

pub fn stop(self: *Self) void {
    self.mut.lock();
    for (self.work.items) |w| {
        w.cleanup(w);
    }
    self.work.clearAndFree();
    self.mut.unlock();
    self.cond.broadcast();
    self.deinit();
}

pub fn wait(self: *Self) !void {
    self.waiting = true;
    try self.addLowPriority(waitBroadcast, .{self});
    for (self.threads) |*t| {
        t.join();
    }
    self.running = false;
    self.deinit();
}

fn waitBroadcast(self: *Self) void {
    self.cond.broadcast();
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.threads);
    self.work.deinit();
}

pub fn addHighPriority(self: *Self, comptime func: anytype, args: anytype) !void {
    const WorkClosure = struct {
        pool: *Self,
        args: @TypeOf(args),
        wrk: Work = .{
            .run = run,
            .cleanup = cleanup,
        },

        fn run(w: *Work) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("wrk", w));
            @call(.auto, func, closure.args);
            closure.pool.alloc.destroy(closure);
        }
        fn cleanup(w: *Work) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("wrk", w));
            closure.pool.alloc.destroy(closure);
        }
    };
    const c = try self.alloc.create(WorkClosure);
    c.* = .{
        .pool = self,
        .args = args,
    };
    try self.work.append(&c.wrk);
    self.cond.signal();
}

pub fn addLowPriority(self: *Self, comptime func: anytype, args: anytype) !void {
    const WorkClosure = struct {
        pool: *Self,
        args: @TypeOf(args),
        wrk: Work = .{
            .run = run,
            .cleanup = cleanup,
        },

        fn run(w: *Work) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("wrk", w));
            @call(.auto, func, closure.args);
            closure.pool.alloc.destroy(closure);
        }
        fn cleanup(w: *Work) void {
            const closure: *@This() = @alignCast(@fieldParentPtr("wrk", w));
            closure.pool.alloc.destroy(closure);
        }
    };
    const c = try self.alloc.create(WorkClosure);
    c.* = .{
        .pool = self,
        .args = args,
    };
    try self.work.insert(0, &c.wrk);
    self.cond.signal();
}

fn getWork(self: *Self) ?*Work {
    self.mut.lock();
    defer self.mut.unlock();
    while (self.running and (self.work.items.len == 0 and !self.waiting)) {
        self.cond.wait(&self.mut);
    }
    return self.work.pop();
}

fn workThread(self: *Self) void {
    while (self.running or (self.work.items.len > 0 and !self.waiting)) {
        const wrk = self.getWork();
        if (wrk != null) {
            wrk.?.run(wrk.?);
        }
    }
}

fn testWork(words: []const u8) void {
    std.debug.print("{s}\n", .{words});
}

fn testWait(words: []const u8) void {
    std.posix.nanosleep(5, 0);
    std.debug.print("{s}\n", .{words});
}

test "add threads" {
    var pol: Self = try .init(std.testing.allocator, 12);
    try pol.start();
    try pol.addHighPriority(testWait, .{"YodleWait"});
    try pol.addHighPriority(testWork, .{"Yodle"});
    try pol.addHighPriority(testWait, .{"YodleWait"});
    try pol.addHighPriority(testWork, .{"Yodle"});
    try pol.addHighPriority(testWait, .{"YodleWait"});
    try pol.addHighPriority(testWork, .{"Yodle"});
    try pol.addHighPriority(testWait, .{"YodleWait"});
    try pol.addHighPriority(testWork, .{"Yodle"});
    try pol.wait();
}

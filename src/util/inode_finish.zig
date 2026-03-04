const std = @import("std");
const WaitGroup = std.Thread.WaitGroup;
const Mutex = std.Thread.Mutex;

const Archive = @import("../archive.zig");
const Inode = @import("../inode.zig");
const ExtractionOptions = @import("../options.zig");

const InodeFinish = @This();

const FinishEnum = enum {
    wg,
    fin,
};
pub const FinishUnion = union(FinishEnum) {
    wg: *WaitGroup,
    fin: *InodeFinish,

    pub fn finish(self: FinishUnion) void {
        switch (self) {
            .wg => |wg| wg.finish(),
            .fin => |fin| fin.finish(),
        }
    }
};

alloc: std.mem.Allocator,

inode: Inode,
path: []const u8,
archive: *Archive,
options: ExtractionOptions,
parent_finish: FinishUnion,
fil: ?std.fs.File,
out_err: *?anyerror,

wg: WaitGroup = .{},
mut: Mutex = .{},

pub fn create(
    alloc: std.mem.Allocator,
    inode: Inode,
    path: []const u8,
    archive: *Archive,
    options: ExtractionOptions,
    parent_finish: FinishUnion,
    out_err: *?anyerror,
    fil: ?std.fs.File,
    work_size: usize,
) !*InodeFinish {
    const out = try alloc.create(InodeFinish);
    errdefer alloc.destroy(out);
    out.* = .{
        .alloc = alloc,

        .inode = inode,
        .path = path,
        .archive = archive,
        .options = options,
        .parent_finish = parent_finish,
        .out_err = out_err,
        .fil = fil,
    };
    out.wg.startMany(work_size);
    return out;
}

pub fn finish(self: *InodeFinish) void {
    self.mut.lock();
    {
        defer self.mut.unlock();
        self.wg.finish();
        if (!self.wg.isDone()) return;
    }
    defer {
        self.parent_finish.finish();
        self.alloc.destroy(self);
    }
    if (self.fil == null)
        self.fil = std.fs.cwd().openFile(self.path, .{}) catch |err| {
            if (self.options.verbose)
                self.options.verbose_writer.?.print("Error opening {s} to set metadata: {}\n", .{ self.path, err }) catch {};
            self.out_err.* = err;
            return;
        };
    defer self.fil.?.close();
    self.inode.setMetadata(self.alloc, self.archive, self.fil.?, self.options) catch |err| {
        if (self.options.verbose)
            self.options.verbose_writer.?.print("Error setting metadata to {s}: {}\n", .{ self.path, err }) catch {};
        self.out_err.* = err;
        return;
    };
}

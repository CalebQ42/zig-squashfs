//! A squashfs archive read from a file.
//! Can be used to directly access File's contents or extract to the filesystem.

const std = @import("std");
const File = std.fs.File;

const DecompMgr = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const InodeRef = Inode.Ref;
const SfsFile = @import("file.zig");
const Superblock = @import("super.zig").Superblock;
const Table = @import("table.zig").Table;
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const FragEntry = packed struct {
    start: u64,
    size: packed struct {
        size: u24,
        uncompressed: bool,
        _: u7,
    },
    _: u32,
};

const Archive = @This();

// 4 Gigs
const MEM_SIZE = 4 * 1024 * 1024 * 1024;

parent_alloc: std.mem.Allocator,
alloc: std.heap.FixedBufferAllocator,
fixed_buf: []u8,

fil: OffsetFile,

super: Superblock,

setup: bool = false,

decomp: DecompMgr = undefined,

frag_table: Table(FragEntry) = undefined,
id_table: Table(u16) = undefined,
export_table: Table(InodeRef) = undefined,

/// Default settings using std.Thread.getCpuCount() threads and the minimum of 4gb or half of system memory for memory usage.
pub fn init(alloc: std.mem.Allocator, fil: File) !Archive {
    return initAdvanced(
        alloc,
        fil,
        0,
        try std.Thread.getCpuCount(),
        @min(MEM_SIZE, try std.process.totalSystemMemory() / 2),
    );
}
/// Create the Archive dictating the amount of threads & memory used.
/// If trying to extract a full archive, a large memory size & thread count could help.
/// If you're planning on only interacting with a small number of files, it should be fine to use few threads and a small memory size.
pub fn initAdvanced(alloc: std.mem.Allocator, fil: File, offset: u64, threads: usize, mem: usize) !Archive {
    _ = threads;
    var super: Superblock = undefined;
    const red = try fil.pread(@ptrCast(&super), offset);
    std.debug.assert(red == @sizeOf(Superblock));
    try super.validate();
    const fixed_buf = try alloc.alloc(u8, mem);
    return .{
        .parent_alloc = alloc,
        .alloc = .init(fixed_buf),
        .fixed_buf = fixed_buf,
        .fil = .init(fil, offset),

        .super = super,
    };
}
pub fn deinit(self: *Archive) void {
    self.parent_alloc.free(self.fixed_buf);
    if (self.setup) {
        self.decomp.deinit();
        self.frag_table.deinit();
        self.export_table.deinit();
        self.id_table.deinit();
    }
}

pub fn allocator(self: *Archive) std.mem.Allocator {
    return self.alloc.threadSafeAllocator();
}

pub fn root(self: *Archive) !SfsFile {
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.allocator(), &rdr, &self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const inode: Inode = try .read(self.allocator(), &meta.interface, self.super.block_size);
    return .init(self, inode, "");
}

pub fn open(self: *Archive, path: []const u8) !SfsFile {
    var root_fil = try self.root();
    defer if (!SfsFile.pathIsSelf(path)) root_fil.deinit();
    return root_fil.open(path);
}

pub fn extract(self: *Archive, path: []const u8, options: ExtractionOptions) !void {
    var root_fil = try self.root();
    defer root_fil.deinit();
    return root_fil.extract(path, options);
}

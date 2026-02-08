//! A squashfs archive read from a file.
//! Can be used to directly access File's contents or extract to the filesystem.

const std = @import("std");
const File = std.fs.File;
const builtin = @import("builtin");

const Decomp = @import("decomp.zig");
const ExtractionOptions = @import("options.zig");
const Inode = @import("inode.zig");
const InodeRef = Inode.Ref;
const BlockSize = @import("inode_data/file.zig").BlockSize;
const SfsFile = @import("file.zig");
const Superblock = @import("super.zig").Superblock;
const Table = @import("table.zig").Table;
const MetadataReader = @import("util/metadata.zig");
const OffsetFile = @import("util/offset_file.zig");

const config = if (builtin.is_test) .{ .use_c_libs = true } else @import("config");

/// Information about a fragment section. Multiple fragments are contained in the block described by a single FragEntry.
/// The offset into the block and fragment size is stored in the file's inode.
pub const FragEntry = packed struct {
    start: u64,
    size: BlockSize,
    _: u32,
};

const Archive = @This();

// 4 Gigs
const DEFAULT_MEM_SIZE = 4 * 1024 * 1024 * 1024;

parent_alloc: std.mem.Allocator,
alloc: std.heap.ThreadSafeAllocator,
// alloc: std.heap.FixedBufferAllocator,
// fixed_buf: []u8,
thread_count: usize,

fil: OffsetFile,

super: Superblock,

setup: bool = false,

decomp: Decomp.DecompFn,

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
        @min(DEFAULT_MEM_SIZE, try std.process.totalSystemMemory() / 2),
    );
}
/// Create the Archive dictating the amount of threads & memory used.
/// If trying to extract a full archive, a large memory size & thread count could help.
/// If you're planning on only interacting with a small number of files, it should be fine to use few threads and a small memory size.
pub fn initAdvanced(alloc: std.mem.Allocator, fil: File, offset: u64, threads: usize) !Archive {
    var super: Superblock = undefined;
    const red = try fil.pread(@ptrCast(&super), offset);
    std.debug.assert(red == @sizeOf(Superblock));
    try super.validate();
    // const fixed_buf = try alloc.alloc(u8, mem);
    return .{
        .parent_alloc = alloc,
        .alloc = .{ .child_allocator = alloc },
        // .fixed_buf = fixed_buf,
        .thread_count = threads,
        .fil = .init(fil, offset),
        .decomp = switch (super.compression) {
            .gzip => Decomp.gzipDecompress,
            .lzma => Decomp.lzmaDecompress,
            .xz => Decomp.xzDecompress,
            .zstd => Decomp.zstdDecompress,
            .lz4 => if (config.use_c_libs) Decomp.cLz4 else return error.Lz4Unsupported,
            .lzo => if (config.use_c_libs) Decomp.cLzo else return error.LzoUnsupported,
        },

        .super = super,
    };
}
pub fn deinit(self: *Archive) void {
    // self.parent_alloc.free(self.fixed_buf);
    if (self.setup) {
        self.frag_table.deinit();
        self.export_table.deinit();
        self.id_table.deinit();
    }
}

pub fn allocator(self: *Archive) std.mem.Allocator {
    return self.alloc.allocator();
}

fn setupValues(self: *Archive) !void {
    const alloc = self.allocator();
    self.frag_table = try .init(alloc, self.fil, self.decomp, self.super.frag_start, self.super.frag_count);
    self.id_table = try .init(alloc, self.fil, self.decomp, self.super.id_start, self.super.id_count);
    self.export_table = try .init(alloc, self.fil, self.decomp, self.super.export_start, self.super.inode_count);
    self.setup = true;
}

pub fn id(self: *Archive, idx: u32) !u16 {
    if (!self.setup) try self.setupValues();
    return self.id_table.get(idx);
}

pub fn frag(self: *Archive, idx: u32) !FragEntry {
    if (!self.setup) try self.setupValues();
    return self.frag_table.get(idx);
}

pub fn inode(self: *Archive, num: u32) !Inode {
    if (!self.setup) try self.setupValues();
    const ref = try self.export_table.get(num - 1);
    var rdr = try self.fil.readerAt(ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.allocator(), &rdr.interface, &self.decomp);
    try meta.interface.discardAll(ref.block_offset);
    return try .read(self.allocator(), &meta.interface, self.super.block_size);
}

pub fn root(self: *Archive) !SfsFile {
    if (!self.setup) try self.setupValues();
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.allocator(), &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(self.allocator(), &meta.interface, self.super.block_size);
    return .init(self, in, "");
}

pub fn open(self: *Archive, path: []const u8) !SfsFile {
    if (!self.setup) try self.setupValues();
    var root_fil = try self.root();
    defer if (!SfsFile.pathIsSelf(path)) root_fil.deinit();
    return root_fil.open(path);
}

pub fn extract(self: *Archive, path: []const u8, options: ExtractionOptions) !void {
    if (!self.setup) try self.setupValues();
    var alloc = self.allocator();
    var ext_path: []u8 = undefined;
    if (std.fs.cwd().statFile(path)) |stat| {
        if (stat.kind == .directory) {
            ext_path = @constCast(path);
        } else return error.ExtractionPathExists;
    } else |err| {
        if (err == error.FileNotFound) {
            ext_path = @constCast(path);
        } else {
            std.log.err("Error stat-ing extraction path {s}: {}\n", .{ path, err });
            return err;
        }
    }
    defer if (ext_path.len > path.len) alloc.free(ext_path);
    var rdr = try self.fil.readerAt(self.super.root_ref.block_start + self.super.inode_start, &[0]u8{});
    var meta: MetadataReader = .init(self.allocator(), &rdr.interface, self.decomp);
    try meta.interface.discardAll(self.super.root_ref.block_offset);
    const in: Inode = try .read(self.allocator(), &meta.interface, self.super.block_size);
    try in.extractTo(self, ext_path, options);
}

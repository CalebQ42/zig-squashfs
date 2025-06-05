const std = @import("std");

const File = std.fs.File;

const Dir = @import("sfs_file.zig").Dir;
const Superblock = @import("superblock.zig").Superblock;
const FilePReader = @import("preader.zig").PReader(File, File.PReadError, File.pread);
const Inode = @import("inode.zig");
const SfsFile = @import("sfs_file.zig").SfsFile;
const FragEntry = @import("fragment.zig").FragEntry;
const Table = @import("table.zig").Table;

const SfsReader = @This();

alloc: std.mem.Allocator,
super: Superblock,
rdr: FilePReader,
root: Dir,

frag_table: Table(FragEntry),
id_table: Table(u16),
export_table: Table(Inode.Ref),

pub fn init(alloc: std.mem.Allocator, fil: File) !*SfsReader {
    return initWOffset(alloc, fil, 0);
}
pub fn initWOffset(alloc: std.mem.Allocator, fil: File, offset: u64) !*SfsReader {
    const out = try alloc.create(SfsReader);
    errdefer alloc.destroy(out);
    out.* = .{
        .alloc = alloc,
        .rdr = .initWOffset(fil, offset),
        .super = undefined,
        .root = undefined,
    };
    _ = try out.rdr.preadAll(std.mem.asBytes(&out.super), 0);
    try out.super.verify();
    out.root = try .init(out, try .fromRef(out, out.super.root_ref), "", "");
    return out;
}
pub fn deinit(self: *SfsReader) void {
    self.root.deinit();
    self.alloc.destroy(self);
}

pub fn open(self: *SfsReader, path: []const u8) !SfsFile {
    return self.root.open(path);
}

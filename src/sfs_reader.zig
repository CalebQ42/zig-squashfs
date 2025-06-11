const std = @import("std");

const File = std.fs.File;

const Dir = @import("sfs_file.zig").Dir;
const Superblock = @import("superblock.zig").Superblock;
const FilePReader = @import("readers/preader.zig").PReader(File);
const Inode = @import("inode.zig");
const SfsFile = @import("sfs_file.zig").SfsFile;
const FragEntry = @import("fragment.zig").FragEntry;
const Table = @import("table.zig").Table;

const SfsReader = @This();

alloc: std.mem.Allocator,
rdr: FilePReader,

super: Superblock = undefined,
root: Dir = undefined,

frag_table: Table(FragEntry) = undefined,
id_table: Table(u16) = undefined,
export_table: Table(Inode.Ref) = undefined,

pub fn init(alloc: std.mem.Allocator, fil: File) !*SfsReader {
    return initWOffset(alloc, fil, 0);
}
pub fn initWOffset(alloc: std.mem.Allocator, fil: File, offset: u64) !*SfsReader {
    const out = try alloc.create(SfsReader);
    errdefer alloc.destroy(out);
    out.* = .{
        .alloc = alloc,
        .rdr = .initWOffset(fil, offset),
    };
    _ = try out.rdr.preadAll(std.mem.asBytes(&out.super), 0);
    try out.super.verify();
    out.root = try .init(out, try .fromRef(out, out.super.root_ref), "", "");
    out.frag_table = .init(alloc, out.rdr, out.super.compress, out.super.frag_count, out.super.frag_start);
    out.id_table = .init(alloc, out.rdr, out.super.compress, out.super.id_count, out.super.id_start);
    out.export_table = .init(alloc, out.rdr, out.super.compress, out.super.inode_count, out.super.export_start);
    return out;
}
pub fn deinit(self: *SfsReader) void {
    self.root.deinit();
    self.alloc.destroy(self);
}

pub fn open(self: *SfsReader, path: []const u8) !SfsFile {
    return self.root.open(path);
}

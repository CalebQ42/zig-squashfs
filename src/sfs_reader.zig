const std = @import("std");

const File = std.fs.File;

const PReader = @import("preader.zig").PReader;
const SfsFile = @import("sfs_file.zig").SfsFile;
const Superblock = @import("superblock.zig").Superblock;
const FilePReader = PReader(File, File.PReadError, File.pread);
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

const SfsReader = @This();

alloc: std.mem.Allocator,
super: Superblock,
rdr: FilePReader,
root: SfsFile,

pub fn init(alloc: std.mem.Allocator, fil: File, offset: u64) !*SfsReader {
    const out = try alloc.create(SfsReader);
    out.* = .{
        .alloc = alloc,
        .rdr = .initWOffset(fil, offset),
        .super = undefined,
        .root = undefined,
    };
    _ = try out.rdr.preadAll(std.mem.asBytes(&out.super), 0);
    try out.super.verify();
    const off_rdr = out.rdr.readerAt(out.super.root_ref.block + out.super.inode_start);
    var meta_rdr: MetadataReader(@TypeOf(off_rdr)) = try .init(
        alloc,
        out.super.compress,
        off_rdr,
    );
    try meta_rdr.skip(out.super.root_ref.offset);
    out.root = .{
        .directory = .{
            .inode = try .read(alloc, out.super.block_size, &meta_rdr),
            .name = "",
            .rdr = out,
            //TODO: fill dir entries
        },
    };
    return out;
}

pub fn deinit(self: *SfsReader) void {
    self.root.deinit();
    self.alloc.destroy(self);
}

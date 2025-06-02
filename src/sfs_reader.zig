const std = @import("std");

const File = std.fs.File;

const PReader = @import("preader.zig").PReader;
const SfsFile = @import("sfs_file.zig");

const FilePReader = PReader(File, File.PReadError, File.pread);

const SfsReader = @This();

alloc: std.mem.Allocator,
rdr: FilePReader,
root: SfsFile,

pub fn init(alloc: std.mem.Allocator, fil: File, offset: u64) !*SfsReader {
    const out = alloc.create(SfsReader);
    out.* = .{
        .alloc = alloc,
        .rdr = .initWOffset(fil, offset),
        .root = undefined,
    };
    return out;
}

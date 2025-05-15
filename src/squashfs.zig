const std = @import("std");
const fs = std.fs;

const Superblock = @import("superblock.zig").Superblock;
const inode = @import("inode.zig");
const MetadataReader = @import("metadata_reader.zig").MetadataReader;
const File = @import("file.zig").File;
const FileOffsetReader = @import("file_offset_reader.zig").FileOffsetReader;

pub const Reader = struct {
    super: Superblock,
    rdr: fs.File,
    root: File,
    alloc: std.heap.ArenaAllocator,

    pub fn init(filename: []const u8) !Reader {
        var file = try std.fs.cwd().openFile(filename, .{});
        errdefer file.close();
        var alloc: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        errdefer _ = alloc.deinit();
        const super = try file.reader().readStruct(Superblock);
        try super.valid();
        var offset_rdr: FileOffsetReader = .init(&file, super.inode_table + super.root_inode.block_start);
        var root_reader: MetadataReader = try .init(
            super.comp,
            offset_rdr.any(),
            alloc.allocator(),
        );
        defer root_reader.deinit();
        try root_reader.skip(super.root_inode.offset);
        var out: Reader = .{
            .super = super,
            .rdr = file,
            .root = undefined,
            .alloc = alloc,
        };
        out.root = .{
            .inode = try inode.readInode(root_reader.any(), super.block_size, alloc.allocator()),
            .name = "",
            .rdr = &out,
        };
        std.debug.print("init {}\n", .{out});
        return out;
    }

    pub fn deinit(self: *Reader) void {
        self.rdr.close();
        self.alloc.deinit();
    }

    pub fn open(self: *Reader, path: []const u8) !File {
        return self.root.open(path);
    }
};

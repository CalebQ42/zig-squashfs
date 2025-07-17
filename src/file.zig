const std = @import("std");

const dir = @import("directory.zig");

const DirEntry = dir.Entry;
const Inode = @import("inode.zig");
const SfsReader = @import("reader.zig").SfsReader;
const ToReader = @import("reader/to_read.zig").ToRead;
const ExtractionOptions = @import("extract_options.zig");
const DataReader = @import("reader/data.zig").DataReader;
const Compression = @import("superblock.zig").Compression;
const MetadataReader = @import("reader/metadata.zig").MetadataReader;

pub const FileError = error{
    NotRegular,
    NotDirectory,
};

pub fn File(comptime T: type) type {
    return struct {
        const Self = @This();

        rdr: *SfsReader(T),

        inode: Inode,
        name: []const u8,

        /// Directory entries. Only populated on directories.
        entries: ?[]DirEntry = null,
        /// File reader. Only populated on regular files.
        data_reader: ?DataReader(T) = null,

        pub fn init(rdr: *SfsReader(T), inode: Inode, name: []const u8) !Self {
            var out = Self{
                .rdr = rdr,
                .inode = inode,
                .name = name,
            };
            switch (inode.data) {
                .dir => |d| {
                    var meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, &meta, d.size);
                },
                .ext_dir => |d| {
                    var meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, &meta, d.size);
                },
                .file => |f| {
                    out.data_reader = try .init(
                        rdr.alloc,
                        rdr.rdr,
                        rdr.super.comp,
                        f.block,
                        f.size,
                        f.block_sizes,
                        rdr.super.block_size,
                    );
                    if (f.hasFragment()) {
                        try out.data_reader.?.addFragment(
                            try rdr.frag_table.get(f.frag_idx),
                            f.frag_offset,
                        );
                    }
                },
                .ext_file => |f| {
                    out.data_reader = try .init(
                        rdr.alloc,
                        rdr.rdr,
                        rdr.super.comp,
                        f.block,
                        f.size,
                        f.block_sizes,
                        rdr.super.block_size,
                    );
                    if (f.hasFragment()) {
                        try out.data_reader.?.addFragment(
                            try rdr.frag_table.get(f.frag_idx),
                            f.frag_offset,
                        );
                    }
                },
                else => {},
            }
            return out;
        }
        pub fn deinit(self: Self) void {
            self.rdr.alloc.free(self.name);
            self.inode.deinit(self.rdr.alloc);
            if (self.entries != null) {
                for (self.entries.?) |e| {
                    e.deinit(self.rdr.alloc);
                }
                self.rdr.alloc.free(self.entries.?);
            }
            if (self.data_reader != null) {
                self.data_reader.?.deinit();
            }
        }

        pub fn iter(self: Self) !void {
            _ = self;
        }
    };
}

const std = @import("std");

const dir = @import("directory.zig");

const DirEntry = dir.Entry;
const Inode = @import("inode.zig");
const SfsReader = @import("reader.zig").SfsReader;
const ToReader = @import("reader/to_read.zig").ToRead;
const ExtractionOptions = @import("extract_options.zig");
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
        // data_reader: ?DataReader

        pub fn init(rdr: *SfsReader(T), inode: Inode, name: []const u8) !Self {
            var out = Self{
                .rdr = rdr,
                .inode = inode,
                .name = name,
            };
            switch (inode.data) {
                .dir => |d| {
                    const meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, meta, d.size);
                },
                .ext_dir => |d| {
                    const meta = MetadataReader(T).init(
                        rdr.alloc,
                        rdr.super.comp,
                        rdr.rdr,
                        d.block + rdr.super.dir_start,
                    );
                    try meta.skip(d.offset);
                    out.entries = try dir.readDirectory(rdr.alloc, meta, d.size);
                },
                .file => |f| {
                    _ = f;
                    //TODO
                },
                .ext_file => |f| {
                    _ = f;
                    //TODO
                },
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
            // if(self.data_reader != null){
            //     self.data_reader.?.deinit();
            // }
        }
    };
}

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
    NotFound,
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
        pub fn initFromRef(rdr: *SfsReader(T), ref: Inode.Ref, name: []const u8) !Self {
            var meta: MetadataReader(T) = .init(rdr.alloc, rdr.super.comp, rdr.rdr, ref.block + rdr.super.inode_start);
            try meta.skip(ref.offset);
            const inode: Inode = try .init(&meta, rdr.alloc, rdr.super.block_size);
            return .init(rdr, inode, name);
        }
        pub fn initFromEntry(rdr: *SfsReader(T), ent: DirEntry) !Self {
            var meta: MetadataReader(T) = .init(rdr.alloc, rdr.super.comp, rdr.rdr, ent.block + rdr.super.inode_start);
            try meta.skip(ent.offset);
            const inode: Inode = try .init(&meta, rdr.alloc, rdr.super.block_size);
            return .init(rdr, inode, ent.name);
        }
        pub fn deinit(self: Self) void {
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

        pub fn open(self: Self, path: []const u8) !Self {
            if (self.entries == null) return FileError.NotDirectory;
            if (path.len == 0) return self;
            const idx = std.mem.indexOf(u8, path, "/") orelse path.len;
            if (idx == 0) return self.open(path[1..]);
            const name = path[0..idx];
            for (self.entries.?) |e| {
                if (std.mem.eql(u8, e.name, name)) {
                    var fil: Self = try .initFromEntry(self.rdr, e);
                    if (idx >= path.len - 1) return fil;
                    defer fil.deinit();
                    return fil.open(path[idx + 1 ..]);
                }
            }
            return FileError.NotFound;
        }
        pub fn iterate(self: Self) Iterator {
            return .{
                .rdr = self.rdr,
                .entries = self.entries.?,
            };
        }

        const Iterator = struct {
            rdr: *SfsReader(T),
            entries: []DirEntry,

            idx: u32 = 0,

            pub fn next(self: *Iterator) !?File(T) {
                if (self.idx >= self.entries.len) return null;
                const out = try Self.initFromEntry(self.rdr, self.entries[self.idx]);
                self.idx += 1;
                return out;
            }
            pub fn reset(self: *Iterator) void {
                self.idx = 0;
            }
        };
    };
}

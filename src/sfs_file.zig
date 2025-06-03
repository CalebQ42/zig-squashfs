const std = @import("std");

const dir = @import("directory.zig");

const SfsReader = @import("sfs_reader.zig");
const Inode = @import("inode.zig");
const MetadataReader = @import("readers/metadata.zig").MetadataReader;

pub const SfsFile = union(enum) {
    regular: Regular,
    directory: Dir,
    symlink: Sym,
    other: Other,

    pub fn fromRef(rdr: *SfsReader, ref: Inode.Ref, name: []u8) !SfsFile {
        return fromInode(
            rdr,
            try .fromRef(rdr, ref),
            name,
        );
    }
    pub fn fromDirEntry(rdr: *SfsReader, ent: dir.DirEntry) !SfsFile {
        const offset_rdr = rdr.rdr.readerAt(ent.block + rdr.super.inode_start);
        var meta_rdr: MetadataReader(@TypeOf(offset_rdr)) = try .init(rdr.alloc, rdr.super.compress, offset_rdr);
        try meta_rdr.skip(ent.offset);
        return fromInode(
            rdr,
            try .init(
                rdr.alloc,
                rdr.super.block_size,
                &meta_rdr,
            ),
            ent.name,
        );
    }
    pub fn fromInode(rdr: *SfsReader, inode: Inode, name: []u8) !SfsFile {
        return switch (inode.hdr.inode_type) {
            .file, .ext_file => .{ .regular = try .init(rdr, inode, name) },
            .directory, .ext_directory => .{ .directory = try .init(rdr, inode, name) },
            .symlink, .ext_symlink => .{ .symlink = try .init(rdr, inode, name) },
            else => .{ .other = try .init(rdr, inode, name) },
        };
    }
    pub fn deinit(self: SfsFile) void {
        switch (self) {
            .regular => |r| r.deinit(),
            .directory => |d| d.deinit(),
            .symlink => |s| s.deinit(),
            .other => |o| o.deinit(),
        }
    }

    pub const ExtractConfig = struct {
        /// The amount of cpu threads to use for decompresion
        threads: u16,
        /// Attempt to extract a symlink's target as well.
        /// Only works if the target is deeper in the directory tree.
        unbreak_sym: bool = false,
        /// Extract symlinks as their target file instead of as a symlink.
        deref_sym: bool = false,
        /// Verbose logging.
        verbose: bool = false,

        pub fn init() !ExtractConfig {
            return .{
                .threads = @truncate(try std.Thread.getCpuCount()),
            };
        }
    };
};

pub const Regular = struct {
    rdr: *SfsReader,
    name: []u8,
    inode: Inode,

    //TODO: data reader

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !Regular {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        //TODO: start data reader,
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Regular) void {
        self.inode.deinit();
        self.rdr.alloc.free(self.name);
    }

    pub fn size(self: Regular) u64 {
        return switch (self.inode.data) {
            .file => |f| f.size,
            .ext_file => |f| f.size,
            else => unreachable,
        };
    }
};

pub const Dir = struct {
    rdr: *SfsReader,
    name: []u8,
    inode: Inode,

    entries: std.StringArrayHashMap(dir.DirEntry),

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !Dir {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        errdefer rdr.alloc.free(name_cpy);
        @memcpy(name_cpy, name);
        var block: u32 = 0;
        var offset: u16 = 0;
        var size: u32 = 0;
        switch (inode.data) {
            .directory => |d| {
                block = d.block;
                offset = d.offset;
                size = d.size;
            },
            .ext_directory => |d| {
                block = d.block;
                offset = d.offset;
                size = d.size;
            },
            else => unreachable,
        }
        const offset_rdr = rdr.rdr.readerAt(rdr.super.dir_start + block);
        var meta_rdr: MetadataReader(@TypeOf(offset_rdr)) = try .init(
            rdr.alloc,
            rdr.super.compress,
            offset_rdr,
        );
        try meta_rdr.skip(offset);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
            .entries = try dir.readEntries(rdr.alloc, &meta_rdr, size),
        };
    }
    pub fn deinit(self: *Dir) void {
        self.inode.deinit();
        self.rdr.alloc.free(self.name);
        for (self.entries.values()) |e| {
            e.deinit(self.rdr.alloc);
        }
        self.entries.deinit();
    }

    const OpenError = error{
        NotFound,
    };

    pub fn open(self: Dir, path: []const u8) !SfsFile {
        const fil_path = std.mem.trim(u8, path, "/");
        if (fil_path.len == 0) return .{ .directory = self };
        const sep_ind = std.mem.indexOf(u8, fil_path, "/") orelse fil_path.len;
        const fil_name = fil_path[0..sep_ind];
        const ent = self.entries.get(fil_name) orelse {
            return OpenError.NotFound;
        };
        if (sep_ind == fil_path.len) {
            return .initWDirEntry(self.rdr, ent);
        }
        if (ent.inode_type != .directory) return OpenError.NotFound;
        const fil: SfsFile = try .initWDirEntry(self.rdr, ent);
        return fil.directory.open(fil_path[sep_ind..]);
    }

    pub fn iterator(self: Dir) DirIterator {
        return .{
            .rdr = self.rdr,
            .entries = self.entries.values(),
        };
    }
    pub fn nameIterator(self: Dir) NameIterator {
        return .{
            .rdr = self.rdr,
            .entries = self.entries.values(),
        };
    }

    const DirIterator = struct {
        rdr: *SfsReader,
        entries: []dir.DirEntry,
        idx: usize = 0,

        /// Make sure to call deinit() on the returned SfsFile.
        pub fn next(self: *DirIterator) !?SfsFile {
            if (self.idx >= self.entries.len) return null;
            defer self.idx += 1;
            return .initWDirEntry(self.rdr, self.entries[self.idx]);
        }
    };
    const NameIterator = struct {
        rdr: *SfsReader,
        entries: []dir.DirEntry,
        idx: usize = 0,

        pub fn next(self: *DirIterator) ?[]u8 {
            if (self.idx >= self.entries.len) return null;
            defer self.idx += 1;
            return self.entries[self.idx].name;
        }
    };
};

pub const Sym = struct {
    rdr: *SfsReader,
    name: []u8,
    inode: Inode,

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !Sym {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Sym) void {
        self.inode.deinit();
        self.rdr.alloc.free(self.name);
    }
};

pub const Other = struct {
    rdr: *SfsReader,
    name: []u8,
    inode: Inode,

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !Other {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Other) void {
        self.rdr.alloc.free(self.name);
    }
};

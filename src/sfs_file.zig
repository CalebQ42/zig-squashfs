const std = @import("std");

const SfsReader = @import("sfs_reader.zig");
const Inode = @import("inode.zig");

// const SfsFileTypes = enum{
//     regular,
//     directory,
//     symlink,
//     other,
// };

pub const SfsFile = union(enum) {
    regular: Regular,
    directory: Dir,
    symlink: Sym,
    other: Other,

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !SfsFile {
        return switch (inode.hdr.inode_type) {
            .file, .ext_file => .{ .regular = .init(rdr, inode, name) },
            .directory, .ext_directory => .{ .directory = .init(rdr, inode, name) },
            .symlink, .ext_symlink => .{ .symlink = .init(rdr, inode, name) },
            else => .{ .other = .init(rdr, inode, name) },
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
        self.alloc.free(self.name);
    }
};

pub const Dir = struct {
    rdr: *SfsReader,
    name: []u8,
    inode: Inode,

    //TODO: dir entries

    pub fn init(rdr: *SfsReader, inode: Inode, name: []u8) !Dir {
        const name_cpy = try rdr.alloc.alloc(u8, name.len);
        @memcpy(name_cpy, name);
        //TODO: read dir entries,
        return .{
            .rdr = rdr,
            .name = name_cpy,
            .inode = inode,
        };
    }
    pub fn deinit(self: Dir) void {
        self.inode.deinit();
        self.alloc.free(self.name);
    }
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
        self.alloc.free(self.name);
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
        self.alloc.free(self.name);
    }
};

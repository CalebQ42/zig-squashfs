const SfsReader = @import("sfs_reader.zig");
const Inode = @import("inode.zig");

pub const SfsFile = union {
    regular: Regular,
    directory: Dir,
    symlink: Sym,
    other: Misc,

    pub fn init() !SfsFile {}
};

pub const Regular = struct {
    name: []const u8,
    inode: Inode,
    rdr: *SfsReader,
};

pub const Dir = struct {
    name: []const u8,
    inode: Inode,
};

pub const Sym = struct {
    name: []const u8,
    inode: Inode,
};

pub const Misc = struct {
    name: []const u8,
    inode: Inode,
};

const std = @import("std");

const InodeRef = @import("inode.zig").Ref;

pub const Superblock = packed struct {
    magic: u32,
    inode_count: u32,
    mod_time: u32,
    block_size: u32,
    frag_count: u32,
    comp: Compression,
    block_log: u16,
    flags: packed struct {
        _: u4,
        id_uncomp: bool,
        comp_options: bool,
        no_xattr: bool,
        xattr_uncomp: bool,
        has_export: bool,
        de_dupe: bool,
        frag_always: bool,
        no_frag: bool,
        frag_uncomp: bool,
        check: bool,
        data_uncomp: bool,
        inode_uncomp: bool,
    },
    id_count: u16,
    ver_maj: u16,
    ver_min: u16,
    root_ref: InodeRef,
    size: u64,
    id_start: u64,
    xattr_start: u64,
    inode_start: u64,
    dir_start: u64,
    frag_start: u64,
    export_start: u64,
};

pub const DecompressError = error{
    LzoUnavailable,
    Lz4Unavailable,
};

pub const Compression = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,

    pub fn decompress(self: Compression, alloc: std.mem.Allocator, source: anytype, dest: []u8) !usize {
        switch (self) {
            .gzip => {
                const decomp = std.compress.zlib.decompressor(source);
                return decomp.read(dest);
            },
            .lzma => {
                const decomp = try std.compress.lzma.decompress(alloc, source);
                defer decomp.deinit();
                return decomp.read(dest);
            },
            .lzo => return DecompressError.LzoUnavailable,
            .xz => {
                const decomp = try std.compress.xz.decompress(alloc, source);
                defer decomp.deinit();
                return decomp.read(dest);
            },
            .lz4 => return DecompressError.Lz4Unavailable,
            .zstd => {
                const window: [@min(std.compress.zstd.DecompressorOptions.default_window_buffer_len, dest.len)]u8 = undefined;
                const decomp = std.compress.zstd.decompressor(source, .{ .window_buffer = window });
                return decomp.read(dest);
            },
        }
    }
};

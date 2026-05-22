const std = @import("std");

const Decompressor = @import("util/decompressor.zig");

pub const Enum = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub fn StatelessDecomp(val: Enum) !*const Decompressor {
    return switch (val) {
        .gzip => &@import("decomp/zlib.zig").stateless_decompressor,
        .lzma => &@import("decomp/lzma.zig").stateless_decompressor,
        .lzo => error.LzoUnsupported,
        .xz => &@import("decomp/xz.zig").stateless_decompressor,
        .lz4 => error.Lz4Unsupported,
        .zstd => &@import("decomp/zstd.zig").stateless_decompressor,
    };
}

pub const Decomp = union(enum) {
    gzip: @import("decomp/zlib.zig"),
    lzma: @import("decomp/lzma.zig"),
    lzo: void,
    xz: @import("decomp/xz.zig"),
    lz4: void,
    zstd: @import("decomp/zstd.zig"),

    pub fn deinit(self: *Decomp) void {
        switch (self.*) {
            .gzip => self.gzip.deinit(),
            .lzma => self.lzma.deinit(),
            .xz => self.xz.deinit(),
            .zstd => self.zstd.deinit(),
            else => unreachable,
        }
    }

    pub fn decompressor(self: *Decomp) *Decompressor {
        return switch (self.*) {
            .gzip => &self.gzip.interface,
            .lzma => &self.lzma.interface,
            .xz => &self.xz.interface,
            .zstd => &self.zstd.interface,
            else => unreachable,
        };
    }
};

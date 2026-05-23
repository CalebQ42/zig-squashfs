const std = @import("std");

const options = @import("options");

const Decompressor = @import("util/decompressor.zig");

const zlib = if (options.use_zig_decomp) @import("decomp/zig_zlib.zig") else @import("decomp/c_zlib.zig");
const lzma = if (options.use_zig_decomp) @import("decomp/zig_lzma.zig") else @import("decomp/c_lzma.zig");
const lzo = if (options.use_zig_decomp or !options.allow_lzo) void else @import("decomp/c_lzo.zig");
const xz = if (options.use_zig_decomp) @import("decomp/zig_xz.zig") else @import("decomp/c_xz.zig");
const lz4 = if (options.use_zig_decomp) void else @import("decomp/c_lz4.zig");
const zstd = if (options.use_zig_decomp) @import("decomp/zig_zstd.zig") else @import("decomp/c_zstd.zig");

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
        .gzip => &zlib.stateless_decompressor,
        .lzma => &lzma.stateless_decompressor,
        .lzo => if (options.use_zig_decomp or !options.allow_lzo)
            error.LzoUnsupported
        else
            &lzo.stateless_decompressor,
        .xz => &xz.stateless_decompressor,
        .lz4 => if (options.use_zig_decomp)
            error.Lz4Unsupported
        else
            &lz4.stateless_decompressor,
        .zstd => &zstd.stateless_decompressor,
    };
}

pub const Decomp = union(enum) {
    gzip: zlib,
    lzma: lzma,
    lzo: lzo,
    xz: xz,
    lz4: lz4,
    zstd: zstd,

    pub fn init(val: Enum, alloc: std.mem.Allocator) !Decomp {
        return switch (val) {
            .gzip => .{ .gzip = zlib.init(alloc) },
            .lzma => .{ .lzma = .{} },
            .lzo => .{ .lzo = .{} },
            .xz => .{ .xz = .{} },
            .lz4 => .{ .lz4 = .{} },
            .zstd => .{ .zstd = zstd.init(alloc) },
        };
    }
    pub fn deinit(self: *Decomp) void {
        switch (self.*) {
            .gzip => self.gzip.deinit(),
            .zstd => self.zstd.deinit(),
            else => {},
        }
    }

    pub fn decompressor(self: *Decomp) *const Decompressor {
        return switch (self.*) {
            .gzip => &self.gzip.interface,
            .lzma => &lzma.stateless_decompressor,
            .lzo => &lzo.stateless_decompressor,
            .xz => &xz.stateless_decompressor,
            .lz4 => &lz4.stateless_decompressor,
            .zstd => &self.zstd.interface,
        };
    }
};

const std = @import("std");
const Io = std.Io;

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

pub fn StatelessDecomp(val: Enum) !Decompressor {
    return switch (val) {
        .gzip => zlib.stateless_decompressor,
        .lzma => lzma.stateless_decompressor,
        .lzo => if (options.use_zig_decomp or !options.allow_lzo)
            error.LzoUnsupported
        else
            lzo.stateless_decompressor,
        .xz => xz.stateless_decompressor,
        .lz4 => if (options.use_zig_decomp)
            error.Lz4Unsupported
        else
            lz4.stateless_decompressor,
        .zstd => zstd.stateless_decompressor,
    };
}

pub const Decomp = union(enum) {
    gzip: zlib,
    lzma: lzma,
    lzo: lzo,
    xz: xz,
    lz4: lz4,
    zstd: zstd,

    pub fn init(val: Enum, alloc: std.mem.Allocator, io: Io, block_size: u32) !Decomp {
        return switch (val) {
            .gzip => .{ .gzip = if (options.use_zig_decomp) try zlib.init(alloc, io, block_size) else try zlib.init(alloc, io) },
            .lzma => .{ .lzma = if (options.use_zig_decomp) try lzma.init(alloc, io, block_size) else .{} },
            .lzo => if (options.use_zig_decomp or !options.allow_lzo) error.LzoUnsupported else .{ .lzo = .{} },
            .xz => .{ .xz = if (options.use_zig_decomp) try xz.init(alloc, io, block_size) else .{} },
            .lz4 => if (options.use_zig_decomp) error.Lz4Unsupported else .{ .lz4 = .{} },
            .zstd => .{ .zstd = if (options.use_zig_decomp) try zstd.init(alloc, io, block_size) else try zstd.init(alloc, io) },
        };
    }
    pub fn deinit(self: *Decomp, alloc: std.mem.Allocator) void {
        if (options.use_zig_decomp) {
            switch (self.*) {
                .gzip => self.gzip.deinit(),
                .lzma => self.lzma.deinit(),
                .xz => self.xz.deinit(),
                .zstd => self.zstd.deinit(),
                else => {},
            }
        } else {
            switch (self.*) {
                .gzip => self.gzip.deinit(alloc),
                .zstd => self.zstd.deinit(alloc),
                else => {},
            }
        }
    }

    pub fn decompressor(self: *Decomp) *Decompressor {
        return switch (self.*) {
            .gzip => &self.gzip.interface,
            .lzma => &self.lzma.interface,
            .lzo => if (options.use_zig_decomp or !options.allow_lzo) unreachable else &self.lzo.interface,
            .xz => &self.xz.interface,
            .lz4 => if (options.use_zig_decomp) unreachable else &self.lz4.interface,
            .zstd => &self.zstd.interface,
        };
    }
};

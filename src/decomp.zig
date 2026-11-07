const std = @import("std");
const Io = std.Io;

const build = @import("build_config");
const c = @import("c");

const Decomp = @This();

vtable: *const struct {
    decomp: *const fn (d: *Decomp, io: Io, in: []u8, out: []u8) Error!usize,
},

pub fn decompress(self: *Decomp, io: Io, in: []u8, out: []u8) Error!usize {
    return self.vtable.decomp(self, io, in, out);
}

// Types

pub const Enum = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Union = union(Enum) {
    gzip: if (build.zig_decomp) @import("decomp/zig_gzip.zig") else @import("decomp/c_gzip.zig"),
    lzma: if (build.zig_decomp) @import("decomp/zig_lzma.zig") else @import("decomp/c_lzma.zig"),
    lzo: if (build.zig_decomp) void else @import("decomp/c_lzo.zig"),
    xz: if (build.zig_decomp) @import("decomp/zig_xz.zig") else @import("decomp/c_xz.zig"),
    lz4: if (build.zig_decomp) void else @import("decomp/c_lz4.zig"),
    zstd: if (build.zig_decomp) @import("decomp/zig_zstd.zig") else @import("decomp/c_zstd.zig"),

    pub fn init(alloc: std.mem.Allocator, decomp: Enum) !Union {
        return switch (decomp) {
            .gzip => .{ .gzip = try .init(alloc) },
            .lzma => .{ .lzma = try .init(alloc) },
            .lzo => if (build.zig_decomp or !build.allow_lzo) error.LzoUnsupported else .{ .lzo = try .init() },
            .xz => .{ .xz = try .init(alloc) },
            .lz4 => if (build.zig_decomp) error.Lz4Unsupported else .{ .lz4 = .{} },
            .zstd => .{ .zstd = try .init(alloc) },
        };
    }
    pub fn deinit(self: *Union, io: Io) void {
        return switch (self.*) {
            .gzip => self.gzip.deinit(io),
            .lzma => self.lzma.deinit(io),
            .xz => self.xz.deinit(io),
            .zstd => self.zstd.deinit(io),
            else => {},
        };
    }

    pub fn interface(self: *Union) !*Decomp {
        return switch (self.*) {
            .gzip => &self.gzip.interface,
            .lzma => &self.lzma.interface,
            .lzo => if (build.zig_decomp or !build.allow_lzo) error.LzoUnsupported else &self.lzo.interface,
            .xz => &self.xz.interface,
            .lz4 => if (build.zig_decomp) error.Lz4Unsupported else &self.lz4.interface,
            .zstd => &self.zstd.interface,
        };
    }
};

pub const Error = Io.Reader.Error || std.mem.Allocator.Error || Io.Cancelable;

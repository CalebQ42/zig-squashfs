const std = @import("std");
const Io = std.Io;

const build = @import("build_config");
const c = @import("c");

const Decomp = @This();

pub const Enum = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Union = union(Enum) {
    gzip: void,
    lzma: void,
    lzo: void,
    xz: void,
    lz4: void,
    zstd: @import("decomp/c_zstd.zig"),

    pub fn init(alloc: std.mem.Allocator, decomp: Enum) !Union {
        return switch (decomp) {
            .gzip => std.debug.panic("TODO: gzip support\n", .{}),
            .lzma => std.debug.panic("TODO: lzma support\n", .{}),
            .lzo => std.debug.panic("TODO: lzo support\n", .{}),
            .xz => std.debug.panic("TODO: xz support\n", .{}),
            .lz4 => std.debug.panic("TODO: lz4 support\n", .{}),
            .zstd => .{ .zstd = try .init(alloc) },
        };
    }
    pub fn deinit(self: *Union, io: Io) void {
        return switch (self.*) {
            .zstd => self.zstd.deinit(io),
            else => std.debug.panic("TODO\n", .{}),
        };
    }

    pub fn interface(self: *Union) *Decomp {
        switch (self.*) {
            .zstd => return &self.zstd.interface,
            else => std.debug.panic("TODO\n", .{}),
        }
    }
};

vtable: *const struct {
    decomp: *const fn (d: *Decomp, io: Io, in: []u8, out: []u8) Error!usize,
},

pub fn decompress(self: *Decomp, io: Io, in: []u8, out: []u8) Error!usize {
    return self.vtable.decomp(self, io, in, out);
}

pub const Error = Io.Reader.Error || std.mem.Allocator.Error || Io.Cancelable;

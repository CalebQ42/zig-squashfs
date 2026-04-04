const config = @import("config");

const Decompressor = @import("../decomp.zig");

pub fn getStatelessFn(decomp: Enum) !Decompressor.StatelessDecomp {
    if (config.use_zig_decomp) {
        return switch (decomp) {
            .gzip => @import("zig/zlib.zig").stateless,
            .lzma => @import("zig/lzma.zig").stateless,
            .xz => @import("zig/xz.zig").stateless,
            .zstd => @import("zig/zstd.zig").stateless,
            .lz4 => error.ZigLz4Unsupported,
            .lzo => error.ZigLzoUnsupported,
        };
    }
    return switch (decomp) {
        .gzip => @import("c/zlib.zig").stateless,
        .lzma => @import("c/lzma.zig").stateless,
        .lzo => @import("c/lzo.zig").stateless,
        .xz => @import("c/xz.zig").stateless,
        .lz4 => @import("c/lz4.zig").stateless,
        .zstd => @import("c/zstd.zig").stateless,
    };
}

pub const Enum = enum(u16) {
    gzip = 1, // Though officially named gzip, it actually uses zlib.
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const Decomp = if (config.use_zig_decomp)
    union(enum) {
        gzip: @import("zig/zlib.zig"),
        lzma: @import("zig/lzma.zig"),
        xz: @import("zig/xz.zig"),
        zstd: @import("zig/zstd.zig"),

        pub fn deinit(_: *Decomp) void {
            return;
        }
    }
else
    union(enum) {
        gzip: @import("c/zlib.zig"),
        lzma: @import("c/lzma.zig"),
        lzo: @import("c/lzo.zig"),
        xz: @import("c/xz.zig"),
        lz4: @import("c/lz4.zig"),
        zstd: @import("c/zstd.zig"),

        pub fn deinit(self: *Decomp) void {
            switch (self) {
                .gzip => self.gzip.deinit(),
                .lzma => self.lzma.deinit(),
                .xz => self.xz.deinit(),
                .zstd => self.zstd.deinit(),
                else => {},
            }
        }
    };

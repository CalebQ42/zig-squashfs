const config = @import("config");

const Decompressor = @import("../decomp.zig");
const cLz4 = @import("c/lz4.zig");
const cLzma = @import("c/lzma.zig");
const cLzo = @import("c/lzo.zig");
const cXz = @import("c/xz.zig");
const cZlib = @import("c/zlib.zig");
const cZstd = @import("c/zstd.zig");
const zigLzma = @import("zig/lzma.zig");
const zigXz = @import("zig/xz.zig");
const zigZlib = @import("zig/zstd.zig");
const zigZstd = @import("zig/zstd.zig");

pub const Decomp = union(enum) {
    gzip: if (config.use_zig_decomp) zigZlib else cZlib,
    lzma: if (config.use_zig_decomp) zigLzma else cLzma,
    lzo: if (config.use_zig_decomp) void else cLzo,
    xz: if (config.use_zig_decomp) zigXz else cXz,
    lz4: if (config.use_zig_decomp) void else cLz4,
    zstd: if (config.use_zig_decomp) zigZstd else cZstd,

    pub fn deinit(self: *Decomp) void {
        switch (self) {
            .gzip => self.gzip.deinit(),
            .lzma => self.lzma.deinit(),
            .xz => self.xz.deinit(),
            .zstd => self.zstd.deinit(),
            else => {},
        }
    }

    pub fn decompressor(self: *Decomp) *Decompressor {
        return switch (self) {
            .gzip => &self.gzip.interface,
            .lzma => &self.lzma.interface,
            .lzo => &self.lzo.interface,
            .xz => &self.xz.interface,
            .lz4 => &self.lz4.interface,
            .zstd => &self.zstd.interface,
        };
    }
};

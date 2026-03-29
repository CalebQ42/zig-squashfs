const config = @import("config");

const Zlib = if (config.use_zig_decomp) @import("zig/zlib.zig") else @import("c/zlib.zig");
const Lzma = if (config.use_zig_decomp) @import("zig/lzma.zig") else @import("c/lzma.zig");
const Lzo = if (config.use_zig_decomp) void else @import("c/lzo.zig");
const Xz = if (config.use_zig_decomp) @import("zig/xz.zig") else @import("c/xz.zig");
const Lz4 = if (config.use_zig_decomp) void else @import("c/lz4.zig");
const Zstd = if (config.use_zig_decomp) @import("zig/zstd.zig") else @import("c/zstd.zig");

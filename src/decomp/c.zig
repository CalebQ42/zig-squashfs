const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const config = if (builtin.is_test) .{
    .use_zig_decomp = !builtin.link_libc,
    .allow_lzo = false, // Change once LZO compilation is fixed
} else @import("config");

pub const c = @cImport({
    @cInclude("zlib-ng.h");
    @cInclude("lzma.h");
    @cInclude("lz4.h");
    @cInclude("zstd.h");
    @cInclude("zstd_errors.h");
    if (config.allow_lzo)
        @cInclude("lzo/minilzo.h");
});

const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const config = @import("config");

pub const c = @cImport({
    @cInclude("zlib-ng.h");
    @cInclude("lzma.h");
    @cInclude("lz4.h");
    @cInclude("zstd.h");
    @cInclude("zstd_errors.h");
    @cInclude("lzo/minilzo.h");
});

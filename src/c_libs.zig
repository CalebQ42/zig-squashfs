pub const c = @cImport({
    @cInclude("zlib-ng.h");
    @cInclude("lzo/minilzo.h");
    @cInclude("lz4.h");
    @cInclude("zstd.h");
    @cInclude("lzma.h");
});

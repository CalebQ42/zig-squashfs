# zig-squashfs

This is my experiments to learn Zig. Might amount to something. Might not.

A library and application to decompress or view squashfs archives.

## Current State

Overall works, but currently is missing some features (see below). Extraction is a bit slow compared to the normal `unsquashfs` (from my _very_ basic testing it's about ~3x slower). Only properly work on Linux, any other OSes probably won't work fully and are untested.

## Build options

> `-Duse_c_libs`

Instead of using Zig's standard library for decompression, use the system's C libraries. Has the benefit of being much faster and enabling LZO and LZ4 decompression.

> `-Dallow_lzo`

Enable compiling with LZO decompression support. The LZO library currently has some issues with Zig when imported so it's easier to just disable it by default. Only has an effect when using `-Duse_c_libs=true`.

> `-Dversion`

Sets the version of `unsquashfs` shown when `--version` is passed.

## Capabilities

Most features are present except for the following:

* mod_time is not set on extraction
* xattrs are not applied on extraction
* When using Zig decompression libraries then lzo and lz4 compression types are unavailable. I don't _currently_ plan on spending the time to find and validate a library since neither is popular.

## Building considerations

Compilation without `use_c_libs` works completely fine, but Zig has issues with some symbols from the lzo library that needs to be manually fixed. In particular you need to fix the definitions for `lzo_bytep` and `lzo_voidp` to be `*u8` and `?*anyopaque` respectively. Due to this, you have to manually enable LZO decompression using `-Dallow_lzo=true` when building.

```zig
pub const lzo_bytep = @compileError("unable to translate C expr: unexpected token ''");
// /usr/include/lzo/lzoconf.h:148:9
pub const lzo_charp = @compileError("unable to translate C expr: unexpected token ''");
// /usr/include/lzo/lzoconf.h:149:9
pub const lzo_voidp = @compileError("unable to translate C expr: unexpected token ''");
```

to

```zig
pub const lzo_bytep = *u8;
// /usr/include/lzo/lzoconf.h:148:9
pub const lzo_charp = @compileError("unable to translate C expr: unexpected token ''");
// /usr/include/lzo/lzoconf.h:149:9
pub const lzo_voidp = ?*anyopaque;
```

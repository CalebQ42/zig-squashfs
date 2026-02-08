# zig-squashfs

This is my experiments to learn Zig. Might amount to something. Might not.

A library and application to decompress or view squashfs archives.

## Current State

Overall works, but currently is completely single threaded and is missing some features. Extraction is slow. Only properly work on Linux, any other OSes probably won't work fully.

## Build options

> `-Duse_c_libs`

Instead of using Zig's standard library for decompression 

> `-Dversion`

Sets the version of `unsquashfs` shown when `--version` is passed.

## Capabilities

Most features are present except for the following:

* mod_time is not set on extraction
* xattrs are not applied on extraction
* Only zstd c library is implemented (all others result in error.TODO).
* When using Zig decompression libraries then lzo and lz4 compression types are unavailable. I don't _really_ plan on spending the time to find and validate a library since neither is popular.

## Building considerations

Compilation without `use_c_libs` works completely fine, but Zig has issues with some symbols from the lzo library that needs to be manually fixed. In particular you need to fix the definitions for `lzo_bytep` and `lzo_voidp` to be `*u8` and `?*anyopaque` respectively.

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

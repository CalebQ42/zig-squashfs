# zig-squashfs

This is my experiments to learn Zig. Might amount to something. Might not.

A library and application to decompress or view squashfs archives.

## Current State

Overall works, but currently is missing some features ([see below](#capabilities)) and has significantly slow performance compared to `unsquashfs` ([see below](#performance)).

## Build options

> `-Duse_c_libs=true`

Instead of using Zig's standard library for decompression, use the system's C libraries. Has the benefit of being much faster and enabling LZO and LZ4 decompression.

> `-Dallow_lzo=true`

Enable compiling with LZO decompression support. The LZO library currently has some issues with Zig when imported so it's easier to just disable it by default. Only has an effect when using `-Duse_c_libs=true`.

> `-Dvalgrind=true`

Just sets the valgrind build option.

> `-Dversion=0.0.0`

Sets the version of `unsquashfs` shown when `--version` is passed.

## Capabilities

Most features are present except for the following:

* When using Zig decompression libraries then lzo and lz4 compression types are unavailable. I don't _currently_ plan on spending the time to find and validate a library since neither is popular.
* When using C decompression libraries, lzo is not supported by default due to [some issues](#build-considerations). If it's needed it's trivial to fix, but it's easiest to just leave it disabled.

## Performance

This is some basic observation's I've made about this library's performance when compared to `unsquashfs`. Unless otherwise stated, most observations were made when extracting my test archive (which is fairly small and uses zstd compression) and with `--release=fast`.

* Under ideal circumstances, my library is ~60% slower (.12s vs .19s).
* Using Zig decompression libraries *significantly* increases decompression time by ~600%. Under ideal circumstances.
* Performance improvements/regressions will be common. I'm still learning Zig.

Example Times:

* *unsquashfs, multi-threaded*: .12s
* *unsquashfs, single-threaded*: .13s
* *C-libs, single-threaded*: .56s
* *C-libs, multi-threaded*: .19s
* *Zig-libs, single-threaded*: 5.78s
* *Zig-libs, multi-threaded*: 1.08s

## Build considerations

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

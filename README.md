# zig-squashfs

This is my experiments to learn Zig. Might amount to something. Might not.

A library and application to decompress or view squashfs archives.

## Current State

Overall works, but currently is missing some features ([see below](#capabilities)) and has significantly slow performance compared to `unsquashfs` ([see below](#performance)).

## Build options

> `-Duse_zig_decomp=true`

Instead of using C libraries for decompression, use Zig's standard library for decompression. If using this option LZO and LZ4 decomrpession types are unsupported and decompression times will be significantly longer.

> `-Ddynamic=true`

Dynamicly link C libraries (if they're used) instead of statically linking them.

> `-Dallow_lzo=true`

Enable compiling with LZO decompression support. The LZO library currently has some issues with Zig when imported so it's easier to just disable it by default. Only has an effect when using `-Duse_c_libs=true`.

> `-Ddebug=true`

Sets various build options that make debugging easier. Specifically, debug optimization is forced, valgrind support is enabled, error tracing is enabled, stipping is disabled, and copmilation uses LLVM (this is due to some linking issues when on Debug optimization and is required for debugging tools such as `lldb`. In the future this may be removed from the debug flag).

> `-Dversion=0.0.0`

Sets the version of `unsquashfs` shown when `--version` is passed.

## Capabilities

Most features are present except for the following:

* When using Zig decompression libraries then lzo and lz4 compression types are unavailable. I don't _currently_ plan on spending the time to find and validate a library since neither is popular.
* When using C decompression libraries, lzo is not supported by default due to [some issues](#build-considerations). If it's needed it's trivial to fix, but it's easiest to just leave it disabled.

## Performance

This is some basic observation's I've made about this library's performance when compared to `unsquashfs`. Unless otherwise stated, most observations were made when extracting my test archive which is fairly small and uses zstd compression with `-Doptimize=ReleaseFast`.

Currently, my only performance checks are checking execution time, nothing deeper.

* Currently, using my test archive, performance aproximately matches `unsquashfs` when multi-threaded, but significantly slower when single-threaded.
* Using Zig decompression libraries *significantly* increases decompression time by 5x. Under ideal circumstances.
* Performance improvements/regressions will be common. I'm still learning Zig.

Example Times:

* *unsquashfs, multi-threaded*: .15s
* *unsquashfs, single-threaded*: .16s
* *C-libs, single-threaded*: .36s
* *C-libs, multi-threaded*: .14s
* *Zig-libs, single-threaded*: CURRENTLY UNTESTED
* *Zig-libs, multi-threaded*: .76s

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

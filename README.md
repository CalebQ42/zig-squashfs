# zig-squashfs

This is my experiments to learn Zig. Might amount to something. Might not.

A library and application to decompress or view squashfs archives.

## Current State

Overall works, but currently is missing some features ([see below](#capabilities)) and has significantly slow performance compared to `unsquashfs` ([see below](#performance)).

## Build options

> `-Dzig_decomp=true`

Instead of using C libraries for decompression, use Zig's standard library. Much less performant and doesn't support LZ4 and LZO decompression, but more portable.

> '-Dstatic=true'

Staticly link C libraries.

> `-Dallow_lzo=true`

Enable compiling with LZO decompression support. The LZO C library currently has some issues with Zig when imported so it's easier to just disable it by default.

> `-Ddebug=true`

Sets various build options that make debugging easier. Specifically, debug optimization is forced, valgrind support is enabled, error tracing is enabled, stipping is disabled, and copmilation uses LLVM (this is due to some linking issues when on Debug optimization and is required for debugging tools such as `lldb`. In the future this may be removed from the debug flag).

> `-Dversion=0.0.0`

Sets the version of `unsquashfs` shown when `--version` is passed.

## Capabilities

Most features are present except for the following:

* When using Zig decompression libraries then lzo and lz4 compression types are unavailable. I don't _currently_ plan on spending the time to find and validate a library since neither is popular.
* When using C decompression libraries, lzo is not supported by default due to [some issues](#build-considerations). If it's needed it's trivial to fix, but it's easiest to just leave it disabled for now.

## Performance

Currently my unsquashfs is slightly slower (about 15% slower) when multi-threaded and A LOT slower (over 2x slower) when single-threaded. In both cases, my unsquashfs uses slightly less memory. Using `zig_decomp` makes it over 60x slower. The benchmarks are done using [hyperfine](https://github.com/sharkdp/hyperfine).

Using C libraries:

```
Testing Multi-threaded Performance

Benchmark 1: unsquashfs -d testing/LinuxPAReference testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  195.5 ±   6.6  188.0 … 205.9
  Memory [MiB]    165.0 ±   0.4  164.5 … 166.1

Benchmark 2: zig-out/bin/unsquashfs -d testing/LinuxPABinTest testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  217.7 ±   5.6  210.8 … 226.6   +11.4%
  Memory [MiB]    143.4 ±   0.2  143.0 … 143.9   -13.1%


Testing Single-threaded Performance

Benchmark 1: unsquashfs -p 1 -d testing/LinuxPAReference testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  269.3 ±   2.0  266.0 … 271.7
  Memory [MiB]    162.4 ±   0.5  162.0 … 163.8

Benchmark 2: zig-out/bin/unsquashfs -p 1 -d testing/LinuxPABinTest testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  544.7 ±   9.5  526.5 … 553.5  +102.2%  (2.0x slower)
  Memory [MiB]    136.2 ±   0.2  135.9 … 136.4   -16.2%
```

Using Zig standard library:

```
Testing Multi-threaded Performance

Benchmark 1: unsquashfs -d testing/LinuxPAReference testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  195.1 ±   7.3  180.7 … 208.5
  Memory [MiB]    164.9 ±   0.2  164.6 … 165.2

Benchmark 2: zig-out/bin/unsquashfs -d testing/LinuxPABinTest testing/LinuxPATest.sfs (10 runs)
                     mean ±     σ      min …     max
  Wall Time [ms]  12729.2 ± 144.0  12480.2 … 12955.6  +6425.9%  (65.3x slower)
  Memory [MiB]      150.0 ±   0.3    149.7 …   150.7     -9.0%


Testing Single-threaded Performance

Benchmark 1: unsquashfs -p 1 -d testing/LinuxPAReference testing/LinuxPATest.sfs (10 runs)
                   mean ±     σ    min …   max
  Wall Time [ms]  268.1 ±   1.4  265.8 … 271.2
  Memory [MiB]    162.2 ±   0.1  162.0 … 162.4

Benchmark 2: zig-out/bin/unsquashfs -p 1 -d testing/LinuxPABinTest testing/LinuxPATest.sfs (10 runs)
                     mean ±     σ      min …     max
  Wall Time [ms]  32038.1 ±  68.2  31959.2 … 32187.9  +11849.6%  (119.5x slower)
  Memory [MiB]      137.2 ±   0.4    136.7 …   138.0     -15.4%
```

## Build considerations

Zig has issues with some symbols from the lzo library that needs to be manually fixed if you need lzo decompression support. In particular you need to fix the definitions for `lzo_bytep` and `lzo_voidp` to be `*u8` and `?*anyopaque` respectively. Due to this, you have to manually enable LZO decompression using `-Dallow_lzo=true` when building.

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

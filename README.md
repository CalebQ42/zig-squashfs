# zig-squashfs

Messing around with zig via making a squashfs library. May amount to something. Or not.

## Current state

Performance is pretty terrible, but overall the library should fully work for decompression. Lzo & Lz4 decompression are not supported as they are not a part of zig's stdlib (support may be added later with external libraries).

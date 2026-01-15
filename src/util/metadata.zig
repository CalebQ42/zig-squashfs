const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;
const StreamError = std.Io.Reader.StreamError;

const DecompMgr = @import("../decomp.zig");

const This = @This();

rdr: Reader,
decomp: *DecompMgr,

buf: [8192]u8 = undefined,

interface: Reader,

pub fn init(rdr: Reader, decomp: *DecompMgr) This {
    return .{
        .rdr = rdr,
        .decomp = decomp,
        .interface = .{
            .buffer = &[0]u8{},
            .end = 0,
            .seek = 0,
            .vtable = &{
                .stream = stream,
            },
        },
    };
}

fn stream(rdr: *Reader, wrt: *Writer, limit: Limit) StreamError!usize{
}

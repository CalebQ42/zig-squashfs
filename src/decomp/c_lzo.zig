const std = @import("std");
const Io = std.Io;

const c = @import("c");

const Decomp = @import("../decomp.zig");
const ResourceQueue = @import("../utils/resource_queue.zig").ResourceQueue;

const Lzo = @This();

interface: Decomp = .{
    .vtable = &.{
        .decomp = decompress,
    },
},

pub fn init() !Lzo {
    const res = c.lzo_init();
    if(res != c.LZO_E_OK){
        std.debug.print("lzo_init error code: {}\n", .{res});
        return error.LzoInit;
    }
    return .{};
}

fn decompress(_: *Decomp, _: Io, in: []u8, out: []u8) Decomp.Error!usize {
    var out_len = out.len;
    const res = c.lzo1x_decompress_safe(in.ptr, in.len, in.ptr, &out_len, null);
    if (res != c.LZO_E_OK) {
        std.debug.print("lzo error code: {}\n", .{res});
        return Decomp.Error.ReadFailed;
    }
    return out_len;
}

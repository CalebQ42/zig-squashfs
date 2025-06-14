const PReader = @import("../util/preader.zig").PReader;

pub fn MetadataReader(comptime T: type) type {
    return struct {
        rdr: PReader(T)
    };
}

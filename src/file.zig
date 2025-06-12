pub fn SfsFile(comptime T: type) type {
    return struct {
        p_rdr: T,
    };
}

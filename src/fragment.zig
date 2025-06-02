pub const FragEntry = packed struct {
    start: u64,
    size: u32, //Replace with BlockSize
    _: u32,
};

//! DataReader reads a regular file's data linearly from start to finish using Io.Reader interface.

const std = @import("std");
const Io = std.Io;

const BlockSize = @import("../inode_data/file.zig").BlockSize;
const Decompressor = @import("decompressor.zig");
const OffsetFile = @import("offset_file.zig");

const DataExtractor = @This();

fil: OffsetFile,
decomp: *const Decompressor,
block_size: u32,

file_size: u64,
cur_offset: u64,
blocks: []BlockSize,

interface: Io.Reader,

//! The DataExtractor is meant to extract a regular file's data to a given file asyncronously.

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
start: u64,
blocks: []BlockSize,

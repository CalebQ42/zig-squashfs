//! Implementations for decompression.
//! TODO: change to vtable interface to allow for shared decompressors for better performance/resource usage.

const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const config = if (builtin.is_test) .{ .use_c_libs = true } else @import("config");

const c = @cImport({
    @cInclude("zstd.h");
});

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

pub const DecompFn = *const fn (alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize; // TODO: replace anyerror to definitive error types.

pub const gzipDecompress = if (config.use_c_libs) cGzip else zigGzip;

fn zigGzip(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, out.len);
    defer alloc.free(buf);
    var decomp = std.compress.flate.Decompress.init(&rdr, .zlib, buf);
    return decomp.reader.readSliceShort(out);
}
fn cGzip(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return error.TODO;
}

pub const lzmaDecompress = if (config.use_c_libs) cLzma else zigLzma;

fn zigLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.lzma.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}
fn cLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return error.TODO;
}

pub const xzDecompress = if (config.use_c_libs) cXz else zigXz;

fn zigXz(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.xz.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}
fn cXz(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    _ = in;
    _ = out;
    return error.TODO;
}

pub const zstdDecompress = if (config.use_c_libs) cZstd else zigZstd;

pub fn zigZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(buf);
    var decomp = std.compress.zstd.Decompress.init(&rdr, buf, .{});
    return decomp.reader.readSliceShort(out) catch |err| {
        return decomp.err orelse err;
    };
}
fn cZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) == 0) return res;
    return switch (c.ZSTD_getErrorCode(res)) {
        c.ZSTD_error_prefix_unknown => cZstdError.PrefixUnknown,
        c.ZSTD_error_version_unsupported => cZstdError.VersionUnsupported,
        c.ZSTD_error_frameParameter_unsupported => cZstdError.FrameParameterUnsupported,
        c.ZSTD_error_frameParameter_windowTooLarge => cZstdError.FrameParameterWindowTooLarge,
        c.ZSTD_error_corruption_detected => cZstdError.CorruptionDetected,
        c.ZSTD_error_checksum_wrong => cZstdError.ChecksumWrong,
        c.ZSTD_error_literals_headerWrong => cZstdError.LiteralsHeaderWrong,
        c.ZSTD_error_dictionary_corrupted => cZstdError.DictionaryCorrupted,
        c.ZSTD_error_dictionary_wrong => cZstdError.DictionaryWrong,
        c.ZSTD_error_dictionaryCreation_failed => cZstdError.DictionaryCreationFailed,
        c.ZSTD_error_parameter_unsupported => cZstdError.ParameterUnsupported,
        c.ZSTD_error_parameter_combination_unsupported => cZstdError.ParameterCombinationUnsupported,
        c.ZSTD_error_parameter_outOfBound => cZstdError.ParameterOutOfBound,
        c.ZSTD_error_tableLog_tooLarge => cZstdError.TableLogTooLarge,
        c.ZSTD_error_maxSymbolValue_tooLarge => cZstdError.MaxSymbolValueTooLarge,
        c.ZSTD_error_maxSymbolValue_tooSmall => cZstdError.MaxSymbolValueTooSmall,
        c.ZSTD_error_cannotProduce_uncompressedBlock => cZstdError.CannotProduceUncompressedBlock,
        c.ZSTD_error_stabilityCondition_notRespected => cZstdError.StabilityConditionNotRespected,
        c.ZSTD_error_stage_wrong => cZstdError.StageWrong,
        c.ZSTD_error_init_missing => cZstdError.InitMissing,
        c.ZSTD_error_memory_allocation => cZstdError.MemoryAllocation,
        c.ZSTD_error_workSpace_tooSmall => cZstdError.WorkSpaceTooSmall,
        c.ZSTD_error_dstSize_tooSmall => cZstdError.DstSizeTooSmall,
        c.ZSTD_error_srcSize_wrong => cZstdError.SrcSizeWrong,
        c.ZSTD_error_dstBuffer_null => cZstdError.DstBufferNull,
        c.ZSTD_error_noForwardProgress_destFull => cZstdError.NoForwardProgressDestFull,
        c.ZSTD_error_noForwardProgress_inputEmpty => cZstdError.NoForwardProgressInputEmpty,
        c.ZSTD_error_frameIndex_tooLarge => cZstdError.FrameIndexTooLarge,
        c.ZSTD_error_seekableIO => cZstdError.SeekableIo,
        c.ZSTD_error_dstBuffer_wrong => cZstdError.DstBufferWrong,
        c.ZSTD_error_srcBuffer_wrong => cZstdError.SrcBufferWrong,
        c.ZSTD_error_sequenceProducer_failed => cZstdError.SequenceProducerFailed,
        c.ZSTD_error_externalSequences_invalid => cZstdError.ExternalSequencesInvalid,
        c.ZSTD_error_maxCode => cZstdError.MaxCode,
        else => cZstdError.Generic,
    };
}

pub const cZstdError = error{
    Generic,
    PrefixUnknown,
    VersionUnsupported,
    FrameParameterUnsupported,
    FrameParameterWindowTooLarge,
    CorruptionDetected,
    ChecksumWrong,
    LiteralsHeaderWrong,
    DictionaryCorrupted,
    DictionaryWrong,
    DictionaryCreationFailed,
    ParameterUnsupported,
    ParameterCombinationUnsupported,
    ParameterOutOfBound,
    TableLogTooLarge,
    MaxSymbolValueTooLarge,
    MaxSymbolValueTooSmall,
    CannotProduceUncompressedBlock,
    StabilityConditionNotRespected,
    StageWrong,
    InitMissing,
    MemoryAllocation,
    WorkSpaceTooSmall,
    DstSizeTooSmall,
    SrcSizeWrong,
    DstBufferNull,
    NoForwardProgressDestFull,
    NoForwardProgressInputEmpty,
    FrameIndexTooLarge,
    SeekableIo,
    DstBufferWrong,
    SrcBufferWrong,
    SequenceProducerFailed,
    ExternalSequencesInvalid,
    MaxCode,
};

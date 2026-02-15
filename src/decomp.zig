//! Implementations for decompression.
//! TODO: change to vtable interface to allow for shared decompressors for better performance/resource usage.

const std = @import("std");
const Reader = std.Io.Reader;
const builtin = @import("builtin");

const config = if (builtin.is_test) .{
    .use_c_libs = builtin.link_libc == true,
    .allow_lzo = false, // Change once LZO compilation is fixed
} else @import("config");

const c = @cImport({
    @cInclude("zlib.h");
    @cInclude("lzma.h");
    @cInclude("lz4.h");
    @cInclude("zstd.h");
    @cInclude("zstd_errors.h");
    if (config.allow_lzo)
        @cInclude("lzo/minilzo.h");
});

pub const CompressionType = enum(u16) {
    gzip = 1,
    lzma,
    lzo,
    xz,
    lz4,
    zstd,
};

/// A generic decompression function. alloc is only used for internal use and any allocations made will be freed.
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
    var out_len: usize = out.len;
    const res = c.uncompress(out.ptr, &out_len, in.ptr, in.len);
    return switch (res) {
        c.Z_OK => out_len,
        c.Z_MEM_ERROR => error.NotEnoughMemory,
        c.Z_BUF_ERROR => error.OutBufferTooSmall,
        c.Z_DATA_ERROR => error.BadData,
        else => error.UnknownResult,
    };
}

pub const lzmaDecompress = if (config.use_c_libs) cLzma else zigLzma;

fn zigLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.lzma.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}
fn cLzma(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    var stream: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.lzma_alone_decoder(&stream, in.len * 2);
    switch (res) {
        c.LZMA_OK => {},
        c.LZMA_MEM_ERROR => return error.LzmaMemoryError,
        c.LZMA_PROG_ERROR => return error.LzmaProgramError,
        else => return error.UnknownResult,
    }
    defer c.lzma_end(&stream);
    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);
    return switch (res) {
        c.LZMA_STREAM_END => stream.total_out,
        c.LZMA_MEM_ERROR => error.LzmaMemoryError,
        c.LZMA_MEMLIMIT_ERROR => error.LzmaMemoryLimit,
        c.LZMA_FORMAT_ERROR => error.LzmaBadFormat,
        c.LZMA_DATA_ERROR => error.LzmaDataCorrupt,
        c.LZMA_BUF_ERROR => error.LzmaCannotProgress,
        c.LZMA_PROG_ERROR => error.LzmaProgramError,
        else => error.UnknownResult,
    };
}

// pub const lzoDecompress = if (config.use_c_libs) cLzo else zigLzo;

// fn zigLzo(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
//     _ = alloc;
//     _ = in;
//     _ = out;
//     return error.LzoUnsupported;
// }
pub fn cLzo(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    var res = c.lzo_init();
    if (res != 0) return error.LzoInitFailed;
    var out_len: usize = out.len;
    res = c.lzo1x_decompress(in.ptr, in.len, out.ptr, &out_len, null);
    return switch (res) {
        c.LZO_E_OK => out_len,
        c.LZO_E_ERROR => error.LzoError,
        c.LZO_E_OUT_OF_MEMORY => error.LzoOutOfMemory,
        c.LZO_E_NOT_COMPRESSIBLE => error.LzoNotCompressible,
        c.LZO_E_INPUT_OVERRUN => error.LzoInputOverrun,
        c.LZO_E_OUTPUT_OVERRUN => error.LzoOutputOverrun,
        c.LZO_E_LOOKBEHIND_OVERRUN => error.LzoLookbehindOverrun,
        c.LZO_E_EOF_NOT_FOUND => error.LzoEofNotFound,
        c.LZO_E_INPUT_NOT_CONSUMED => error.LzoInputNotConsumed,
        c.LZO_E_NOT_YET_IMPLEMENTED => error.LzoNotYetImplemented,
        c.LZO_E_INVALID_ARGUMENT => error.LzoInvalidArgument,
        c.LZO_E_INVALID_ALIGNMENT => error.LzoInvalidAlignment,
        c.LZO_E_OUTPUT_NOT_CONSUMED => error.LzoOutputNotConsumed,
        c.LZO_E_INTERNAL_ERROR => error.LzoInternalError,
        else => error.UnknownResult,
    };
}

pub const xzDecompress = if (config.use_c_libs) cXz else zigXz;

fn zigXz(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    var decomp = try std.compress.xz.decompress(alloc, rdr.adaptToOldInterface());
    return decomp.read(out);
}
fn cXz(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    var stream: c.lzma_stream = .{
        .next_in = in.ptr,
        .avail_in = in.len,
        .next_out = out.ptr,
        .avail_out = out.len,
    };
    var res = c.lzma_stream_decoder(&stream, in.len * 2, 0);
    switch (res) {
        c.LZMA_OK => {},
        c.LZMA_MEM_ERROR => return error.LzmaMemoryError,
        c.LZMA_PROG_ERROR => return error.LzmaProgramError,
        else => return error.UnknownResult,
    }
    defer c.lzma_end(&stream);
    while (res == c.LZMA_OK)
        res = c.lzma_code(&stream, c.LZMA_RUN);
    return switch (res) {
        c.LZMA_STREAM_END => stream.total_out,
        c.LZMA_MEM_ERROR => error.LzmaMemoryError,
        c.LZMA_MEMLIMIT_ERROR => error.LzmaMemoryLimit,
        c.LZMA_FORMAT_ERROR => error.LzmaBadFormat,
        c.LZMA_DATA_ERROR => error.LzmaDataCorrupt,
        c.LZMA_BUF_ERROR => error.LzmaCannotProgress,
        c.LZMA_PROG_ERROR => error.LzmaProgramError,
        else => error.UnknownResult,
    };
}

// pub const lz4Decompress = if (config.use_c_libs) cLz4 else zigLz4;

// fn zigLz4(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
//     _ = alloc;
//     _ = in;
//     _ = out;
//     return error.Lz4Unsupported;
// }
pub fn cLz4(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    const res = c.LZ4_decompress_safe(in.ptr, out.ptr, @intCast(in.len), @intCast(out.len));
    if (res > 0) return @abs(res); // TODO: Find out what error values it can return.
    return error.Lz4DecompressFailed;
}

pub const zstdDecompress = if (config.use_c_libs) cZstd else zigZstd;

pub fn zigZstd(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    var rdr: Reader = .fixed(in);
    const buf = try alloc.alloc(u8, 1024 * 1024);
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

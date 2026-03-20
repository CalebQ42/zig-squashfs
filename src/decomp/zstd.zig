const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const DCtx = c.ZSTD_DCtx;

const Self = @This();

alloc: std.mem.Allocator,
ctx: std.AutoHashMap(std.Thread.Id, DCtx),

pub fn init(alloc: std.mem.Allocator) !Self {
    return .{
        .alloc = alloc,
        .ctx = .init(alloc),
    };
}
pub fn deinit(self: Self) void {
    var iter = self.ctx.keyIterator();
    while (iter.next()) |key| {
        _ = c.ZSTD_freeDCtx(self.ctx.getPtr(key));
    }
    self.ctx.deinit(self.alloc);
}

pub fn decompress(self: *Self, in: []u8, out: []u8) ZstdError!usize {
    const ctx = try self.getOrCreate();
    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    try checkError(res);
    return res;
}
inline fn getOrCreate(self: *Self) ZstdError!*DCtx {
    const res = try self.ctx.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) {
        try checkError(c.ZSTD_DCtx_reset(res.value_ptr, c.ZSTD_reset_session_only));
        return res.value_ptr;
    }
    res.value_ptr.* = c.ZSTD_createDCtx() orelse return ZstdError.OutOfMemory;
    return res.value_ptr;
}

fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) anyerror!usize {
    _ = alloc;
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    try checkError(res);
    return res;
}

inline fn checkError(res: usize) !void {
    if (res == 0) return;
    if (c.ZSTD_isError(res) == 0) return;
    return switch (c.ZSTD_getErrorCode(res)) {
        c.ZSTD_error_prefix_unknown => ZstdError.PrefixUnknown,
        c.ZSTD_error_version_unsupported => ZstdError.VersionUnsupported,
        c.ZSTD_error_frameParameter_unsupported => ZstdError.FrameParameterUnsupported,
        c.ZSTD_error_frameParameter_windowTooLarge => ZstdError.FrameParameterWindowTooLarge,
        c.ZSTD_error_corruption_detected => ZstdError.CorruptionDetected,
        c.ZSTD_error_checksum_wrong => ZstdError.ChecksumWrong,
        c.ZSTD_error_literals_headerWrong => ZstdError.LiteralsHeaderWrong,
        c.ZSTD_error_dictionary_corrupted => ZstdError.DictionaryCorrupted,
        c.ZSTD_error_dictionary_wrong => ZstdError.DictionaryWrong,
        c.ZSTD_error_dictionaryCreation_failed => ZstdError.DictionaryCreationFailed,
        c.ZSTD_error_parameter_unsupported => ZstdError.ParameterUnsupported,
        c.ZSTD_error_parameter_combination_unsupported => ZstdError.ParameterCombinationUnsupported,
        c.ZSTD_error_parameter_outOfBound => ZstdError.ParameterOutOfBound,
        c.ZSTD_error_tableLog_tooLarge => ZstdError.TableLogTooLarge,
        c.ZSTD_error_maxSymbolValue_tooLarge => ZstdError.MaxSymbolValueTooLarge,
        c.ZSTD_error_maxSymbolValue_tooSmall => ZstdError.MaxSymbolValueTooSmall,
        c.ZSTD_error_stabilityCondition_notRespected => ZstdError.StabilityConditionNotRespected,
        c.ZSTD_error_stage_wrong => ZstdError.StageWrong,
        c.ZSTD_error_init_missing => ZstdError.InitMissing,
        c.ZSTD_error_memory_allocation => ZstdError.MemoryAllocation,
        c.ZSTD_error_workSpace_tooSmall => ZstdError.WorkSpaceTooSmall,
        c.ZSTD_error_dstSize_tooSmall => ZstdError.DstSizeTooSmall,
        c.ZSTD_error_srcSize_wrong => ZstdError.SrcSizeWrong,
        c.ZSTD_error_dstBuffer_null => ZstdError.DstBufferNull,
        c.ZSTD_error_noForwardProgress_destFull => ZstdError.NoForwardProgressDestFull,
        c.ZSTD_error_noForwardProgress_inputEmpty => ZstdError.NoForwardProgressInputEmpty,
        else => ZstdError.Generic,
    };
}
pub const ZstdError = error{
    OutOfMemory,
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

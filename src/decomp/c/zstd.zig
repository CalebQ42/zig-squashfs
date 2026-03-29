const std = @import("std");

const c = @import("../../c_libs.zig").c;
const Decompressor = @import("../../decomp.zig");

const Zstd = @This();

context: std.AutoHashMap(std.Thread.Id, ?*c.ZSTD_DCtx),

interface: Decompressor,

err: ?Error = null,

pub fn init(alloc: std.mem.Allocator) !Zstd {
    return .{
        .streams = try .init(alloc),
        .interface = .{
            .alloc = alloc,
            .vtable = .{ .decompress = decompress, .stateless = stateless },
        },
    };
}

fn getOrCreate(self: *Zstd) !*c.ZSTD_DCtx {
    const res = try self.context.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) return res.value_ptr;
    res.value_ptr.* = c.ZSTD_createDCtx();
    if (res.value_ptr.* == null) return Error.OutOfMemory;
}

fn decompress(decomp: *Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Zstd = @fieldParentPtr("interface", decomp);

    const ctx = self.getOrCreate();
    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    decodeError(res) catch |err| {
        self.err = err;
        return ZstdErrorToDecompError(err);
    };
    return res;
}
fn stateless(alloc: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    _ = alloc;
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    decodeError(res) catch |err| return ZstdErrorToDecompError(err);
    return res;
}

inline fn decodeError(res: usize) Error!void {
    if (c.ZSTD_isError(res) == 0) return;
    return switch (c.ZSTD_getErrorCode(res)) {
        c.ZSTD_error_GENERIC => Error.Generic,
        c.ZSTD_error_prefix_unknown => Error.PrefixUnknown,
        c.ZSTD_error_version_unsupported => Error.VersionUnsupported,
        c.ZSTD_error_frameParameter_unsupported => Error.FrameParameterUnsupported,
        c.ZSTD_error_frameParameter_windowTooLarge => Error.FrameParameterWindowTooLarge,
        c.ZSTD_error_corruption_detected => Error.CorruptionDetected,
        c.ZSTD_error_checksum_wrong => Error.ChecksumWrong,
        c.ZSTD_error_literals_headerWrong => Error.LiteralsHeaderWrong,
        c.ZSTD_error_dictionary_corrupted => Error.DictionaryCorrupted,
        c.ZSTD_error_dictionary_wrong => Error.DictionaryWrong,
        c.ZSTD_error_dictionaryCreation_failed => Error.DictionaryCreationFailed,
        c.ZSTD_error_parameter_unsupported => Error.ParameterUnsupported,
        c.ZSTD_error_parameter_combination_unsupported => Error.ParameterCombinationUnsupported,
        c.ZSTD_error_parameter_outOfBound => Error.ParameterOutOfBound,
        c.ZSTD_error_tableLog_tooLarge => Error.TableLogTooLarge,
        c.ZSTD_error_maxSymbolValue_tooLarge => Error.MaxSymbolValueTooLarge,
        c.ZSTD_error_maxSymbolValue_tooSmall => Error.MaxSymbolValueTooSmall,
        c.ZSTD_error_cannotProduce_uncompressedBlock => Error.CannotProduceUncompressedBlock,
        c.ZSTD_error_stabilityCondition_notRespected => Error.StabilityConditionNotRespected,
        c.ZSTD_error_stage_wrong => Error.StageWrong,
        c.ZSTD_error_init_missing => Error.InitMissing,
        c.ZSTD_error_memory_allocation => Error.MemoryAllocation,
        c.ZSTD_error_workSpace_tooSmall => Error.WorkSpaceTooSmall,
        c.ZSTD_error_dstSize_tooSmall => Error.DstSizeTooSmall,
        c.ZSTD_error_srcSize_wrong => Error.SrcSizeWrong,
        c.ZSTD_error_dstBuffer_null => Error.DstBufferNull,
        c.ZSTD_error_noForwardProgress_destFull => Error.NoForwardProgressDestFull,
        c.ZSTD_error_noForwardProgress_inputEmpty => Error.NoForwardProgressInputEmpty,
        c.ZSTD_error_frameIndex_tooLarge => Error.FrameIndexTooLarge,
        c.ZSTD_error_seekableIO => Error.SeekableIo,
        c.ZSTD_error_dstBuffer_wrong => Error.DstBufferWrong,
        c.ZSTD_error_srcBuffer_wrong => Error.SrcBufferWrong,
        c.ZSTD_error_sequenceProducer_failed => Error.SequenceProducerFailed,
        c.ZSTD_error_externalSequences_invalid => Error.ExternalSequencesInvalid,
    };
}
inline fn ZstdErrorToDecompError(err: Error) Decompressor.Error {
    return switch (err) {
        Error.OutOfMemory => err,
        Error.Generic => Decompressor.Error.ReadFailed,
        Error.PrefixUnknown => Decompressor.Error.ReadFailed,
        Error.VersionUnsupported => Decompressor.Error.ReadFailed,
        Error.FrameParameterUnsupported => Decompressor.Error.ReadFailed,
        Error.FrameParameterWindowTooLarge => Decompressor.Error.ReadFailed,
        Error.CorruptionDetected => Decompressor.Error.ReadFailed,
        Error.ChecksumWrong => Decompressor.Error.ReadFailed,
        Error.LiteralsHeaderWrong => Decompressor.Error.ReadFailed,
        Error.DictionaryCorrupted => Decompressor.Error.ReadFailed,
        Error.DictionaryWrong => Decompressor.Error.ReadFailed,
        Error.DictionaryCreationFailed => Decompressor.Error.ReadFailed,
        Error.ParameterUnsupported => Decompressor.Error.ReadFailed,
        Error.ParameterCombinationUnsupported => Decompressor.Error.ReadFailed,
        Error.ParameterOutOfBound => Decompressor.Error.ReadFailed,
        Error.TableLogTooLarge => Decompressor.Error.ReadFailed,
        Error.MaxSymbolValueTooLarge => Decompressor.Error.ReadFailed,
        Error.MaxSymbolValueTooSmall => Decompressor.Error.ReadFailed,
        Error.CannotProduceUncompressedBlock => Decompressor.Error.ReadFailed,
        Error.StabilityConditionNotRespected => Decompressor.Error.ReadFailed,
        Error.StageWrong => Decompressor.Error.ReadFailed,
        Error.InitMissing => Decompressor.Error.ReadFailed,
        Error.MemoryAllocation => Decompressor.Error.OutOfMemory,
        Error.WorkSpaceTooSmall => Decompressor.Error.WriteFailed,
        Error.DstSizeTooSmall => Decompressor.Error.WriteFailed,
        Error.SrcSizeWrong => Decompressor.Error.ReadFailed,
        Error.DstBufferNull => Decompressor.Error.WriteFailed,
        Error.NoForwardProgressDestFull => Decompressor.Error.WriteFailed,
        Error.NoForwardProgressInputEmpty => Decompressor.Error.ReadFailed,
        Error.FrameIndexTooLarge => Decompressor.Error.ReadFailed,
        Error.SeekableIo => Decompressor.Error.ReadFailed,
        Error.DstBufferWrong => Decompressor.Error.WriteFailed,
        Error.SrcBufferWrong => Decompressor.Error.ReadFailed,
        Error.SequenceProducerFailed => Decompressor.Error.ReadFailed,
        Error.ExternalSequencesInvalid => Decompressor.Error.ReadFailed,
    };
}

pub const Error = error{
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
};

const std = @import("std");
const builtin = @import("builtin");

const Decompressor = @import("../decomp.zig");
const c = @import("c.zig").c;
const DCtx = c.ZSTD_DCtx;

const Self = @This();

alloc: std.mem.Allocator,
ctx: std.AutoHashMap(std.Thread.Id, *DCtx),

interface: Decompressor = .{ .vtable = &.{
    .decompress = decompress,
    .stateless = stateless,
} },
err: ?ZstdError = null,

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

pub fn decompress(decomp: *Decompressor, in: []u8, out: []u8) Decompressor.Error!usize {
    var self: *Self = @fieldParentPtr("interface", decomp);

    const ctx = try self.getOrCreate();
    const res = c.ZSTD_decompressDCtx(ctx, out.ptr, out.len, in.ptr, in.len);
    try self.checkError(res);
    return res;
}
inline fn getOrCreate(self: *Self) Decompressor.Error!*DCtx {
    const res = try self.ctx.getOrPut(std.Thread.getCurrentId());
    if (res.found_existing) {
        try self.checkError(c.ZSTD_DCtx_reset(res.value_ptr.*, c.ZSTD_reset_session_only));
        return res.value_ptr.*;
    }
    res.value_ptr.* = c.ZSTD_createDCtx() orelse return Decompressor.Error.OutOfMemory;
    return res.value_ptr.*;
}

fn stateless(_: std.mem.Allocator, in: []u8, out: []u8) Decompressor.Error!usize {
    const res = c.ZSTD_decompress(out.ptr, out.len, in.ptr, in.len);
    if (c.ZSTD_isError(res) == 0) return res;
    return switch (c.ZSTD_getErrorCode(res)) {
        c.ZSTD_error_memory_allocation => Decompressor.Error.OutOfMemory,
        c.ZSTD_error_workSpace_tooSmall,
        c.ZSTD_error_dstSize_tooSmall,
        c.ZSTD_error_dstBuffer_null,
        c.ZSTD_error_noForwardProgress_destFull,
        => Decompressor.Error.OutputTooSmall,
        else => Decompressor.Error.BadInput,
    };
}

inline fn checkError(self: *Self, res: usize) Decompressor.Error!void {
    if (res == 0) return;
    if (c.ZSTD_isError(res) == 0) return;
    switch (c.ZSTD_getErrorCode(res)) {
        c.ZSTD_error_prefix_unknown => {
            self.err = ZstdError.PrefixUnknown;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_version_unsupported => {
            self.err = ZstdError.VersionUnsupported;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_frameParameter_unsupported => {
            self.err = ZstdError.FrameParameterUnsupported;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_frameParameter_windowTooLarge => {
            self.err = ZstdError.FrameParameterWindowTooLarge;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_corruption_detected => {
            self.err = ZstdError.CorruptionDetected;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_checksum_wrong => {
            self.err = ZstdError.ChecksumWrong;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_literals_headerWrong => {
            self.err = ZstdError.LiteralsHeaderWrong;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_dictionary_corrupted => {
            self.err = ZstdError.DictionaryCorrupted;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_dictionary_wrong => {
            self.err = ZstdError.DictionaryWrong;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_dictionaryCreation_failed => {
            self.err = ZstdError.DictionaryCreationFailed;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_parameter_unsupported => {
            self.err = ZstdError.ParameterUnsupported;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_parameter_combination_unsupported => {
            self.err = ZstdError.ParameterCombinationUnsupported;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_parameter_outOfBound => {
            self.err = ZstdError.ParameterOutOfBound;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_tableLog_tooLarge => {
            self.err = ZstdError.TableLogTooLarge;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_maxSymbolValue_tooLarge => {
            self.err = ZstdError.MaxSymbolValueTooLarge;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_maxSymbolValue_tooSmall => {
            self.err = ZstdError.MaxSymbolValueTooSmall;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_stabilityCondition_notRespected => {
            self.err = ZstdError.StabilityConditionNotRespected;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_stage_wrong => {
            self.err = ZstdError.StageWrong;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_init_missing => {
            self.err = ZstdError.InitMissing;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_memory_allocation => {
            self.err = ZstdError.MemoryAllocation;
            return Decompressor.Error.OutOfMemory;
        },
        c.ZSTD_error_workSpace_tooSmall => {
            self.err = ZstdError.WorkSpaceTooSmall;
            return Decompressor.Error.OutputTooSmall;
        },
        c.ZSTD_error_dstSize_tooSmall => {
            self.err = ZstdError.DstSizeTooSmall;
            return Decompressor.Error.OutputTooSmall;
        },
        c.ZSTD_error_srcSize_wrong => {
            self.err = ZstdError.SrcSizeWrong;
            return Decompressor.Error.BadInput;
        },
        c.ZSTD_error_dstBuffer_null => {
            self.err = ZstdError.DstBufferNull;
            return Decompressor.Error.OutputTooSmall;
        },
        c.ZSTD_error_noForwardProgress_destFull => {
            self.err = ZstdError.NoForwardProgressDestFull;
            return Decompressor.Error.OutputTooSmall;
        },
        c.ZSTD_error_noForwardProgress_inputEmpty => {
            self.err = ZstdError.NoForwardProgressInputEmpty;
            return Decompressor.Error.BadInput;
        },
        else => {
            self.err = ZstdError.Generic;
            return Decompressor.Error.BadInput;
        },
    }
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
